import Foundation

/// A word Coucou writes another way: "cloud code" → "Claude Code".
struct FlowReplacement: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var from: String
    var to: String
}

/// Say the trigger, get the whole text: "ma signature" → "Belle journée,\nLouis".
struct FlowSnippet: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var trigger: String
    var text: String
}

/// What Coucou does to the words before pasting them, and the numbers of the Statistics page
/// (tests/FlowTextTests.swift). No AppKit here: it runs in the tests as it is.
enum FlowText {
    /// Snippets first (their trigger is said as is), then the replacements, then the words of the
    /// dictionary get their exact spelling ("supabase" → "Supabase").
    static func apply(_ text: String, words: [String], replacements: [FlowReplacement], snippets: [FlowSnippet]) -> String {
        var out = text
        for snippet in snippets where !snippet.text.isEmpty {
            out = replacing(snippet.trigger, with: snippet.text, in: out)
        }
        for replacement in replacements where !replacement.to.isEmpty {
            out = replacing(replacement.from, with: replacement.to, in: out)
        }
        for word in words where isPlainWord(word) {
            out = replacing(word, with: word, in: out)
        }
        return out
    }

    /// Every occurrence of `phrase`, ignoring case and what separates its words
    /// ("rendez vous", "Rendez-vous"), but only as whole words: "art" never matches in "partir".
    static func replacing(_ phrase: String, with replacement: String, in text: String) -> String {
        guard let regex = pattern(for: phrase) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// Whether `phrase` appears in `text` as whole words.
    static func contains(_ phrase: String, in text: String) -> Bool {
        guard let regex = pattern(for: phrase) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func pattern(for phrase: String) -> NSRegularExpression? {
        let parts = tokens(phrase)
        guard !parts.isEmpty else { return nil }
        let body = parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^\\p{L}\\p{N}]+")
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])",
                                        options: [.caseInsensitive])
    }

    /// Only words made of letters, digits, spaces, hyphens and apostrophes get their spelling fixed:
    /// "C++" would match every lone "c".
    static func isPlainWord(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter || $0.isNumber }.count
        return letters >= 2 && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "'" || $0 == "’" }
    }

    /// The letters-and-digits runs of a phrase: "Rendez-vous !" → ["Rendez", "vous"].
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber { current.append(ch) }
            else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Words as you would count them: "c'est" is one word, a lone "?" none.
    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    // MARK: - Numbers

    /// Typing speed used to tell how much time dictating saved.
    static let typingWordsPerMinute = 45.0

    static func wordsPerMinute(words: Int, seconds: Double) -> Int {
        guard seconds >= 1, words > 0 else { return 0 }
        return Int((Double(words) / (seconds / 60)).rounded())
    }

    /// Minutes saved: what typing the words would have taken, less the time spent speaking them.
    static func minutesSaved(words: Int, seconds: Double) -> Double {
        max(0, Double(words) / typingWordsPerMinute - seconds / 60)
    }

    /// Days in a row with at least one dictation, ending today (or yesterday, if today has none yet).
    static func streak(days: Set<String>, today: Date, calendar: Calendar = .current) -> Int {
        var day = calendar.startOfDay(for: today)
        if !days.contains(dayKey(day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(dayKey(day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// "2026-10-14", in the user's time zone.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 36 800 → "36,8 k" in French, "36.8K" in English: short numbers for the stat cards.
    static func shortCount(_ n: Int, locale: Locale = .current) -> String {
        guard n >= 10_000 else { return n.formatted(.number.locale(locale)) }
        let thousands = Double(n) / 1000
        let rounded = thousands >= 100 ? thousands.rounded() : (thousands * 10).rounded() / 10
        return rounded.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + " k"
    }
}
