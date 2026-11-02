import Foundation
import UIKit

/// Where the brain is and the token it expects (the same two values as the pairing QR code).
struct Pairing: Equatable {
    var url: String
    var token: String

    /// "192.168.1.20:8765" or "http://192.168.1.20:8765/" → "http://192.168.1.20:8765".
    var baseURL: URL? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let parsed = URL(string: text), parsed.host != nil else { return nil }
        return parsed
    }
}

/// One line of the conversation, sent back to the brain as context ("and tomorrow?").
struct Turn: Codable, Equatable, Identifiable {
    var id = UUID()
    let role: String  // "user" | "assistant"
    let text: String
    var image: UIImage? = nil  // a glasses photo CJ looked at (shown in the app, never sent as history)

    enum CodingKeys: String, CodingKey { case role, text }
}

/// "Remind me in 10 minutes": the phone runs the timer.
struct TimerRequest: Decodable, Equatable {
    let seconds: Int
    let label: String?
}

/// Something only the phone can do, handed back by the brain with its answer:
/// call_number {number}, visual_memory {on}, translate {language}, phone_task {goal}, dictation {session}, timer.
struct PhoneAction: Decodable, Equatable {
    let action: String
    var number: String? = nil
    var on: Bool? = nil
    var language: String? = nil
    var goal: String? = nil
    var session: String? = nil
    var seconds: Int? = nil
    var label: String? = nil

    /// From a live-session "phone" event (a JSON object).
    init?(event: [String: Any]) {
        guard let action = event["action"] as? String else { return nil }
        self.action = action
        number = event["number"] as? String
        on = event["on"] as? Bool
        language = event["language"] as? String
        goal = event["goal"] as? String
        session = event["session"] as? String
        seconds = (event["seconds"] as? NSNumber)?.intValue
        label = event["label"] as? String
    }
}

struct Answer: Decodable {
    let spoken: String
    let details: String?
    let language: String?
    let ms: Int?
    let timer: TimerRequest?
    let phone: PhoneAction?
}

/// A Claude Code job on the Mac that finished since the phone last asked.
struct FinishedJob: Decodable {
    let project: String
    let state: String
    let summary: String
}

struct SpokenAnswer: Decodable {
    let heard: String
    let spoken: String
    let language: String?
    let needsPhoto: Bool
    let timer: TimerRequest?
    let phone: PhoneAction?

    enum CodingKeys: String, CodingKey { case heard, spoken, language, timer, phone, needsPhoto = "needs_photo" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heard = try c.decodeIfPresent(String.self, forKey: .heard) ?? ""
        spoken = try c.decodeIfPresent(String.self, forKey: .spoken) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language)
        needsPhoto = try c.decodeIfPresent(Bool.self, forKey: .needsPhoto) ?? false
        timer = try? c.decodeIfPresent(TimerRequest.self, forKey: .timer)
        phone = try? c.decodeIfPresent(PhoneAction.self, forKey: .phone)
    }
}

enum BrainError: LocalizedError {
    case badAddress
    case unreachable(String)
    case rejectedToken
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .badAddress: return "La dirección del cerebro no es válida. Ejemplo: 192.168.1.20:8765"
        case .unreachable(let url): return "No llego al cerebro en \(url). ¿Está run.sh en marcha y estás en la misma Wi-Fi?"
        case .rejectedToken: return "El cerebro ha rechazado el token. Revisa que sea el de la línea Console de run.sh."
        case .server(let code, let text): return "El cerebro respondió con error \(code): \(text)"
        }
    }
}

/// Talks to the CJ brain (cj-mac/cj/main.py) over HTTP. Every call sends the pairing token.
struct BrainClient {
    let pairing: Pairing

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 40   // a spoken answer can take a while
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// GET /health: which AI providers the brain can use. Doesn't need the token, so it also checks the address alone.
    func health() async throws -> [String: Bool] {
        struct Health: Decodable { let ok: Bool; let providers: [String: Bool] }
        let health: Health = try await call("GET", "/health")
        return health.providers
    }

    /// GET /api/notes: a harmless call that needs the token, so it proves the pairing without spending an AI request.
    func checkToken() async throws {
        struct Notes: Decodable {}
        let _: Notes = try await call("GET", "/api/notes")
    }

    /// POST /api/ask with a typed question and the last few turns for context.
    /// [imageJpegBase64]: a photo from the glasses, for "what is this" or "add this to my calendar".
    func ask(_ text: String, history: [Turn], imageJpegBase64: String? = nil) async throws -> Answer {
        struct AskIn: Encodable {
            let text: String; let history: [Turn]; let voice: Bool
            let image_b64: String?; let mime: String
        }
        let body = try JSONEncoder().encode(AskIn(text: text, history: Array(history.suffix(8)), voice: false,
                                                  image_b64: imageJpegBase64, mime: "image/jpeg"))
        return try await call("POST", "/api/ask", body: body)
    }

    /// POST /api/ask with a recorded question (WAV). The brain transcribes it, and says whether it must look through
    /// the glasses first (needs_photo) instead of answering.
    func askSpoken(_ wav: Data, history: [Turn]) async throws -> SpokenAnswer {
        struct AskIn: Encodable {
            let audio_b64: String; let audio_mime = "audio/wav"; let history: [Turn]; let voice = false
        }
        let body = try JSONEncoder().encode(AskIn(audio_b64: wav.base64EncodedString(), history: Array(history.suffix(8))))
        return try await call("POST", "/api/ask", body: body)
    }

    /// GET /api/jobs/done: Claude Code jobs that finished on the Mac (each is returned once).
    func finishedJobs() async throws -> [FinishedJob] {
        struct Jobs: Decodable { let jobs: [FinishedJob] }
        let jobs: Jobs = try await call("GET", "/api/jobs/done")
        return jobs.jobs
    }

    /// POST /api/glance: one visual-memory photo. True when the brain kept a note of it (the photo isn't stored).
    func glance(jpegBase64: String) async throws -> Bool {
        struct GlanceIn: Encodable { let image_b64: String; let mime = "image/jpeg" }
        struct Kept: Decodable { let kept: Bool }
        let kept: Kept = try await call("POST", "/api/glance", body: try JSONEncoder().encode(GlanceIn(image_b64: jpegBase64)))
        return kept.kept
    }

    private func call<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        guard let base = pairing.baseURL, let url = URL(string: base.absoluteString + path) else { throw BrainError.badAddress }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(pairing.token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw BrainError.unreachable(base.absoluteString)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw BrainError.rejectedToken }
        guard (200..<300).contains(code) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
                ?? String(decoding: data.prefix(160), as: UTF8.self)
            throw BrainError.server(code, detail)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
