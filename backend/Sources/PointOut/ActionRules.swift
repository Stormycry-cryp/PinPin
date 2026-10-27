import CoreGraphics
import Foundation
import NaturalLanguage

/// Selection language, output and tag helpers. Images are never recognized locally.
enum ActionRules {
    // MARK: Languages

    enum Script: Equatable { case han, kana, hangul, latin, cyrillic, arabic, other }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
             0xAC00...0xD7AF, 0x20000...0x2FFFF: return true
        default: return false
        }
    }

    static func dominantScript(_ text: String) -> Script? {
        var counts: [Script: Int] = [:]
        for s in text.unicodeScalars {
            let script: Script?
            switch s.value {
            case 0x3040...0x30FF: script = .kana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: script = .han
            case 0xAC00...0xD7AF, 0x1100...0x11FF: script = .hangul
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: script = .latin
            case 0x400...0x4FF: script = .cyrillic
            case 0x600...0x6FF: script = .arabic
            default: script = nil
            }
            if let script { counts[script, default: 0] += 1 }
        }
        // Any kana marks Japanese text, which mixes kana and han.
        if let kana = counts[.kana], kana > 0, (counts[.han] ?? 0) + kana >= (counts[.latin] ?? 0) { return .kana }
        return counts.max { $0.value < $1.value }?.key
    }

    static func script(forLanguage code: String) -> Script {
        switch baseLanguage(code) {
        case "zh": return .han
        case "ja": return .kana
        case "ko": return .hangul
        case "ru", "uk", "bg", "sr": return .cyrillic
        case "ar", "fa", "ur": return .arabic
        default: return .latin
        }
    }

    static func baseLanguage(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code)).lowercased()
    }

    /// BCP-47 code of the user's first preferred language, e.g. zh-Hans, en, ja.
    static func homeLanguage(preferred: [String] = Locale.preferredLanguages) -> String {
        guard let first = preferred.first else { return "zh-Hans" }
        let base = baseLanguage(first)
        if base == "zh" {
            let lower = first.lowercased()
            return lower.contains("hant") || lower.hasSuffix("-tw") || lower.hasSuffix("-hk") || lower.hasSuffix("-mo")
                ? "zh-Hant" : "zh-Hans"
        }
        return base
    }

    /// A confident language guess for text long enough to judge, else nil.
    static func detectLanguage(_ text: String) -> String? {
        let sample = String(text.prefix(400))
        guard sample.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
              probability >= 0.6 else { return nil }
        return language.rawValue
    }

    struct TranslationPlan: Equatable {
        /// The text to translate.
        var text: String
        /// nil when unknown; the model then identifies it.
        var source: String?
        var target: String
        /// True when only a pointed term inside a home-language passage is translated.
        var pointedTerm: Bool
        var subtitle: String
    }

    /// Direction is fixed locally, never left to the model: text not in the user's language is
    /// translated into it; text already in it is translated into English (Chinese for English
    /// users). A foreign term pointed at inside home-language text is translated on its own.
    static func translationPlan(unit: String, pointed: String?, home: String) -> TranslationPlan {
        let homeBase = baseLanguage(home)
        let detected = detectLanguage(unit)
        let isHome: Bool
        if let detected { isHome = baseLanguage(detected) == homeBase }
        else { isHome = dominantScript(unit).map { $0 == script(forLanguage: home) } ?? true }
        if !isHome {
            return TranslationPlan(text: unit, source: detected, target: home, pointedTerm: false,
                                   subtitle: subtitle(from: detected, to: home))
        }
        if let pointed = pointed?.trimmingCharacters(in: .whitespacesAndNewlines), !pointed.isEmpty,
           pointed != unit.trimmingCharacters(in: .whitespacesAndNewlines),
           let pointedScript = dominantScript(pointed), pointedScript != script(forLanguage: home) {
            let source = detectLanguage(pointed)
            return TranslationPlan(text: pointed, source: source, target: home, pointedTerm: true,
                                   subtitle: subtitle(from: source, to: home))
        }
        let secondary = homeBase == "en" ? "zh-Hans" : "en"
        return TranslationPlan(text: unit, source: detected ?? home, target: secondary, pointedTerm: false,
                               subtitle: subtitle(from: detected ?? home, to: secondary))
    }

    static func shortName(_ code: String) -> String {
        switch baseLanguage(code) {
        case "zh": return "中"
        case "en": return "英"
        case "ja": return "日"
        case "ko": return "韩"
        case "fr": return "法"
        case "de": return "德"
        case "es": return "西"
        case "ru": return "俄"
        case "it": return "意"
        case "pt": return "葡"
        default: return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) ?? code
        }
    }

    static func subtitle(from source: String?, to target: String) -> String {
        guard let source else { return "译为\(shortName(target))文" }
        return "\(shortName(source)) → \(shortName(target))"
    }

    /// Unambiguous name for the model prompt.
    static func promptName(_ code: String) -> String {
        switch code {
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁体中文"
        default: return Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
        }
    }

    // MARK: Output budget

    /// Translate and rewrite outputs scale with the input; short text keeps a small budget.
    static func outputTokens(for text: String) -> Int {
        min(1600, max(240, text.count + 120))
    }

    // MARK: Tags

    static func normalizedTag(_ raw: String) -> String? {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !tag.isEmpty, tag.count <= 16 else { return nil }
        return tag
    }

    static func normalizedTags(_ raw: [String], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in raw {
            guard let tag = normalizedTag(value), seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
            if result.count == limit { break }
        }
        return result
    }

    /// Reads the first JSON string array in a model reply. Anything else yields no tags.
    static func parseTags(_ reply: String, limit: Int = 3) -> [String] {
        guard let start = reply.firstIndex(of: "["), let end = reply[start...].firstIndex(of: "]"),
              let data = String(reply[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return normalizedTags(array.compactMap { $0 as? String }.filter { $0.count <= 12 }, limit: limit)
    }

    /// Plain text for pasting or replacing: inline Markdown markers removed.
    static func plainText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(attributed.characters)
    }
}
