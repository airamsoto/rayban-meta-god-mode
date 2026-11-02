import Contacts
import EventKit
import Foundation
import UIKit

/// The things the brain can ask the iPhone to do itself during a live conversation (cj-mac/cj/live.py PHONE_ACTIONS):
/// the phone's calendars (iCloud, Outlook/Exchange, Google), Teams links, WhatsApp, calls, reminders and the shopping
/// list, and Apple Shortcuts (which reach Apple Home). Each returns a short plain-text result for the model.
@MainActor
final class PhoneTools: ObservableObject {
    static let actions = ["calendar_events", "calendar_add", "teams_join", "teams_message", "whatsapp", "call",
                          "reminder_add", "list_items", "run_shortcut"]
    static let shoppingList = "Compra"

    @Published private(set) var calendarAllowed = false
    @Published private(set) var remindersAllowed = false
    @Published private(set) var contactsAllowed = false

    /// Called with a number to dial once the conversation ends (a call needs the audio).
    var callRequested: ((String, String) -> Void)?

    private let events = EKEventStore()
    private let contacts = CNContactStore()

    init() { refreshPermissions() }

    func refreshPermissions() {
        calendarAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        contactsAllowed = CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    func requestCalendar() async { _ = try? await events.requestFullAccessToEvents(); refreshPermissions() }
    func requestReminders() async { _ = try? await events.requestFullAccessToReminders(); refreshPermissions() }
    func requestContacts() async { _ = try? await contacts.requestAccess(for: .contacts); refreshPermissions() }

    /// Runs one phone tool and says what happened.
    func run(_ action: String, _ args: [String: Any]) async -> String {
        func s(_ key: String) -> String { (args[key] as? String ?? (args[key].map { "\($0)" } ?? "")).trimmingCharacters(in: .whitespacesAndNewlines) }
        func n(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue ?? Int(s(key)) }
        switch action {
        case "calendar_events": return await calendarEvents(days: n("days") ?? 0, span: max(1, min(14, n("span") ?? 1)))
        case "calendar_add": return await calendarAdd(title: s("title"), date: s("date"), time: s("time"),
                                                      minutes: n("duration_minutes") ?? 60, location: s("location"))
        case "teams_join": return await teamsJoin()
        case "teams_message": return await teamsMessage(to: s("to"), text: s("text"))
        case "whatsapp": return await whatsapp(to: s("to"), text: s("text"))
        case "call": return await call(s("to"))
        case "reminder_add": return await reminderAdd(s("text"), list: s("list"))
        case "list_items": return await listItems(s("list").isEmpty ? Self.shoppingList : s("list"))
        case "run_shortcut": return runShortcut(s("name"))
        default: return "FAILED: unknown phone action \(action)."
        }
    }

    // MARK: - calendar and Teams

    func calendarEvents(days: Int, span: Int) async -> String {
        guard await calendarAccess() else { return "FAILED: CJ has no calendar access. Ask the user to allow it in CJ's settings." }
        let start = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: days, to: .now)!)
        let end = Calendar.current.date(byAdding: .day, value: span, to: start)!
        let found = eventsBetween(start, end)
        guard !found.isEmpty else { return "No events." }
        let day = DateFormatter()
        day.locale = Locale(identifier: "es_ES")
        day.dateFormat = span > 1 ? "EEE d HH:mm" : "HH:mm"
        return found.prefix(15).map { e in
            let when = e.isAllDay ? "todo el día" : day.string(from: e.startDate)
            let extra = [e.location.flatMap { $0.isEmpty ? nil : $0 }, Self.teamsLink(e) != nil ? "Teams" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            return "\(when) \(e.title ?? "(sin título)")" + (extra.isEmpty ? "" : " (\(extra))")
        }.joined(separator: "\n")
    }

    func calendarAdd(title: String, date: String, time: String, minutes: Int, location: String) async -> String {
        guard !title.isEmpty else { return "FAILED: no title." }
        guard await calendarAccess() else { return "FAILED: CJ has no calendar access." }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = time.isEmpty ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        guard let startDate = parser.date(from: time.isEmpty ? date : "\(date) \(time)") else { return "FAILED: bad date or time." }
        let event = EKEvent(eventStore: events)
        event.title = title
        event.startDate = startDate
        event.isAllDay = time.isEmpty
        event.endDate = time.isEmpty ? startDate : startDate.addingTimeInterval(TimeInterval(max(15, minutes) * 60))
        if !location.isEmpty { event.location = location }
        event.calendar = events.defaultCalendarForNewEvents
        do {
            try events.save(event, span: .thisEvent)
            return "Added \(title) to the calendar."
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    func teamsJoin() async -> String {
        guard await calendarAccess() else { return "FAILED: CJ has no calendar access." }
        let now = Date()
        let soon = eventsBetween(now.addingTimeInterval(-3 * 3600), now.addingTimeInterval(24 * 3600))
            .filter { Self.teamsLink($0) != nil && $0.endDate > now }
        guard let meeting = soon.first, let link = Self.teamsLink(meeting) else { return "No Teams meeting today." }
        return open(link, "Opening Teams for \(meeting.title ?? "the meeting").")
    }

    func teamsMessage(to: String, text: String) async -> String {
        var email = to.contains("@") ? to : ""
        if email.isEmpty, let person = await findContact(to) { email = person.emailAddresses.first.map { String($0.value) } ?? "" }
        guard !email.isEmpty else { return "FAILED: no email for \(to) in contacts; ask for their email." }
        var url = URLComponents(string: "https://teams.microsoft.com/l/chat/0/0")!
        url.queryItems = [URLQueryItem(name: "users", value: email), URLQueryItem(name: "message", value: text)]
        return open(url.url!, "Teams chat with \(to) is open with the message typed; the user taps send.")
    }

    private func eventsBetween(_ start: Date, _ end: Date) -> [EKEvent] {
        events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
    }

    private static func teamsLink(_ event: EKEvent) -> URL? {
        if let url = event.url, url.absoluteString.contains("teams.") { return url }
        let text = [event.notes, event.location].compactMap { $0 }.joined(separator: " ")
        guard let range = text.range(of: #"https://teams\.(microsoft|live)\.com/[^\s<>"]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    private func calendarAccess() async -> Bool {
        if !calendarAllowed { await requestCalendar() }
        return calendarAllowed
    }

    // MARK: - people: WhatsApp and calls

    func whatsapp(to: String, text: String) async -> String {
        guard let number = await phoneNumber(for: to) else { return "FAILED: no phone number for \(to) in contacts." }
        var url = URLComponents(string: "whatsapp://send")!
        url.queryItems = [URLQueryItem(name: "phone", value: Self.international(number.digits)),
                          URLQueryItem(name: "text", value: text)]
        return open(url.url!, "WhatsApp chat with \(number.name) is open with the message typed; the user taps send.")
    }

    func call(_ to: String) async -> String {
        guard let number = await phoneNumber(for: to) else { return "FAILED: no phone number for \(to) in contacts." }
        callRequested?(number.digits, number.name)
        return "Calling \(number.name) as soon as you finish speaking (iOS asks to confirm)."
    }

    /// A number as said ("612 34 56 78"), or the best number of a contact by name ("mamá", "Juan García").
    private func phoneNumber(for who: String) async -> (name: String, digits: String)? {
        let digits = who.filter { $0.isNumber || $0 == "+" }
        if digits.filter(\.isNumber).count >= 6 { return (who, digits) }
        guard let person = await findContact(who) else { return nil }
        let numbers = person.phoneNumbers
        let best = numbers.first { $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone } ?? numbers.first
        guard let value = best?.value.stringValue else { return nil }
        let name = CNContactFormatter.string(from: person, style: .fullName) ?? who
        return (name, value.filter { $0.isNumber || $0 == "+" })
    }

    private func findContact(_ name: String) async -> CNContact? {
        guard !name.isEmpty else { return nil }
        if !contactsAllowed { await requestContacts() }
        guard contactsAllowed else { return nil }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey,
                    CNContactEmailAddressesKey, CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] as [Any]
        let store = contacts
        return await Task.detached {
            let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name),
                                                    keysToFetch: keys as! [CNKeyDescriptor])) ?? []
            return found.first { !$0.phoneNumbers.isEmpty || !$0.emailAddresses.isEmpty } ?? found.first
        }.value
    }

    /// WhatsApp wants the country code without "+": a 9-digit Spanish number gets 34 in front.
    static func international(_ number: String) -> String {
        var digits = number
        if digits.hasPrefix("+") { return String(digits.dropFirst()) }
        if digits.hasPrefix("00") { digits.removeFirst(2); return digits }
        let region = Locale.current.region?.identifier ?? "ES"
        if digits.count == 9, region == "ES" { return "34" + digits }
        return digits
    }

    // MARK: - reminders and the shopping list

    func reminderAdd(_ text: String, list: String) async -> String {
        guard !text.isEmpty else { return "FAILED: nothing to add." }
        guard await remindersAccess() else { return "FAILED: CJ has no reminders access." }
        guard let calendar = list.isEmpty ? events.defaultCalendarForNewReminders() : reminderList(list, create: true)
        else { return "FAILED: no reminders list." }
        let reminder = EKReminder(eventStore: events)
        reminder.title = text
        reminder.calendar = calendar
        do {
            try events.save(reminder, commit: true)
            return "Added \(text) to \(calendar.title)."
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    func listItems(_ list: String) async -> String {
        guard await remindersAccess() else { return "FAILED: CJ has no reminders access." }
        let items = await openItems(list)
        return items.isEmpty ? "The \(list) list is empty." : "\(list): " + items.joined(separator: ", ")
    }

    /// The open items of a reminders list (the kitchen screen shows the shopping list).
    func openItems(_ list: String) async -> [String] {
        guard remindersAllowed, let calendar = reminderList(list, create: false) else { return [] }
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        let store = events
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: (found ?? []).compactMap(\.title))
            }
        }
    }

    private func reminderList(_ name: String, create: Bool) -> EKCalendar? {
        if let existing = events.calendars(for: .reminder).first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        guard create, let source = events.defaultCalendarForNewReminders()?.source else { return nil }
        let list = EKCalendar(for: .reminder, eventStore: events)
        list.title = name
        list.source = source
        return (try? events.saveCalendar(list, commit: true)) != nil ? list : nil
    }

    private func remindersAccess() async -> Bool {
        if !remindersAllowed { await requestReminders() }
        return remindersAllowed
    }

    // MARK: - Shortcuts (Apple Home and anything else)

    func runShortcut(_ name: String) -> String {
        guard !name.isEmpty else { return "FAILED: which shortcut?" }
        var url = URLComponents(string: "shortcuts://run-shortcut")!
        url.queryItems = [URLQueryItem(name: "name", value: name)]
        return open(url.url!, "Running the shortcut \(name).")
    }

    // MARK: -

    /// Other apps can only be opened while CJ is on screen (not with the iPhone locked).
    private func open(_ url: URL, _ said: String) -> String {
        guard UIApplication.shared.applicationState == .active else {
            return "FAILED: the iPhone is locked or CJ isn't on screen; ask the user to unlock it and open CJ."
        }
        UIApplication.shared.open(url)
        return said
    }
}
