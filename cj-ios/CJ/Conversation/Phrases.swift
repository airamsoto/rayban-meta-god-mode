import Foundation

/// Phrases that steer a conversation, ported from the Android app (Core.kt, Live.kt) with Spanish added.
/// Keep in sync with cj-android/.../Core.kt and its PhrasesTest / WakeAndStopTest.
enum Phrases {
    /// Said over CJ while it talks, these cut its answer off at once. Whole words only: "bus stand" or "stopwatch"
    /// don't count. ("para" is left out: in Spanish it starts too many normal sentences.)
    static let stopWords = regex(#"(^|[^\p{L}])(stop|ruko|bas|chup|enough|basta|calla|cállate|callate|silencio|रुको|बस|चुप)([^\p{L}]|$)"#)

    private static let stopPhrases = regex(
        #"\b(stop listening|go to sleep|turn (yourself|cj) off|turn off cj|switch off cj|band karo|so jao|chup ho ja|"# +
        #"deja de escuchar|duérmete|duermete|apágate|apagate)\b|^(cj,? )?(turn|switch) off$|बंद करो|सो जाओ"#)

    private static let notForCJ = regex(#"\b(ac|light|lights|fan|tv|music|notes|geyser|plug|luz|luces|tele|música|musica|aire)\b"#)

    private static let byePhrases = regex(
        #"\b(bye( bye)?( cj)?|good ?bye|that'?s all|that is all|that'?s it( for now)?|see you|see ya|"# +
        #"talk (to you )?later|catch you later|later cj|i('ve| have)? (got|gotta) to go|i (gotta|have to|need to|must) go|"# +
        #"gotta go|got to go|i'?m (done|off)|we'?re done|done for (now|today)|nothing else|"# +
        #"chalo bye|ok bye|bas itna hi|bas itna|alvida|phir milte|chalta hu+n?|chalti hu+n?|"# +
        #"adi[oó]s|hasta luego|hasta mañana|hasta otra|nos vemos|chao|chau|eso es todo|nada más|nada mas|"# +
        #"me tengo que ir|me voy|ya está bien|"# +
        #"au revoir|tsch[uü]ss|ciao|tchau|sayonara|ma'?a ?salama|khuda hafiz|allah hafiz)\b|"# +
        #"बाय|अलविदा|फिर मिलते|चलता हूँ|再见|さようなら|до свидания|пока|مع السلامة|খোদা হাফেজ|خدا حافظ"#)

    /// "Stop listening", "deja de escuchar": switches CJ off. Only when that's all that was said, so "turn off the
    /// bedroom lights" goes to the smart home instead.
    static func wantsStop(_ text: String) -> Bool {
        let clean = trimmed(text)
        return matches(stopPhrases, clean) && words(clean) <= 4 && !matches(notForCJ, clean)
    }

    /// "Bye", "adiós", "me tengo que ir": ends the conversation. Only when it's the point of what was said: a short
    /// phrase, or one ending with it. "¿Cómo se dice adiós en francés?" doesn't count.
    static func wantsBye(_ text: String) -> Bool {
        let clean = trimmed(text)
        let ns = clean as NSString
        guard let last = byePhrases.matches(in: clean, range: NSRange(location: 0, length: ns.length)).last else { return false }
        return words(clean) <= 6 || NSMaxRange(last.range) >= ns.length - 1
    }

    static func isStopWord(_ text: String) -> Bool { matches(stopWords, text) }

    // MARK: - helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func trimmed(_ text: String) -> String {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = clean.last, ".!?।¡¿".contains(last) { clean.removeLast() }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
