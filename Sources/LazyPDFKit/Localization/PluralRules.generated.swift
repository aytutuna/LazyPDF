// Copied from Lazy Scan's PluralRules.generated.swift, the CLDR cardinal rules.

enum PluralCategory: String, Sendable {
    case zero, one, two, few, many, other
}

enum PluralRules {
    /// The CLDR cardinal category of `n`. A language without a rule uses the English one.
    static func category(_ n: Int, language: String) -> PluralCategory {
        switch language {
        case "ar":
            if n == 0 { return .zero }
            if n == 1 { return .one }
            if n == 2 { return .two }
            if (n % 100 >= 3 && n % 100 <= 10) { return .few }
            if (n % 100 >= 11 && n % 100 <= 99) { return .many }
            return .other
        case "bn", "gu", "hi", "kn", "vi":
            if n == 0 || n == 1 { return .one }
            return .other
        case "ca", "it", "pt-PT", "es", "es-419":
            if n == 1 { return .one }
            if n != 0 && n % 1000000 == 0 { return .many }
            return .other
        case "zh-Hans", "zh-Hant", "id", "ja", "ko", "ms", "th":
            return .other
        case "hr":
            if n % 10 == 1 && n % 100 != 11 { return .one }
            if (n % 10 >= 2 && n % 10 <= 4) && (n % 100 < 12 || n % 100 > 14) { return .few }
            return .other
        case "cs", "sk":
            if n == 1 { return .one }
            if (n >= 2 && n <= 4) { return .few }
            return .other
        case "fr", "fr-CA", "pt-BR":
            if (n >= 0 && n <= 1) { return .one }
            if n != 0 && n % 1000000 == 0 { return .many }
            return .other
        case "he":
            if n == 1 { return .one }
            if n == 2 { return .two }
            return .other
        case "pl":
            if n == 1 { return .one }
            if (n % 10 >= 2 && n % 10 <= 4) && (n % 100 < 12 || n % 100 > 14) { return .few }
            if n != 1 && (n % 10 >= 0 && n % 10 <= 1) || (n % 10 >= 5 && n % 10 <= 9) || (n % 100 >= 12 && n % 100 <= 14) { return .many }
            return .other
        case "pa":
            if (n >= 0 && n <= 1) { return .one }
            return .other
        case "ro":
            if n == 1 { return .one }
            if n == 0 || n != 1 && (n % 100 >= 1 && n % 100 <= 19) { return .few }
            return .other
        case "ru", "uk":
            if n % 10 == 1 && n % 100 != 11 { return .one }
            if (n % 10 >= 2 && n % 10 <= 4) && (n % 100 < 12 || n % 100 > 14) { return .few }
            if n % 10 == 0 || (n % 10 >= 5 && n % 10 <= 9) || (n % 100 >= 11 && n % 100 <= 14) { return .many }
            return .other
        case "sl":
            if n % 100 == 1 { return .one }
            if n % 100 == 2 { return .two }
            if (n % 100 >= 3 && n % 100 <= 4) { return .few }
            return .other
        default:
            if n == 1 { return .one }
            return .other
        }
    }

    /// Whether `language` has a rule of its own, as opposed to the English fallback.
    static func hasRule(_ language: String) -> Bool {
        switch language {
        case "en", "ar", "bn", "ca", "zh-Hans", "zh-Hant", "hr", "cs", "da", "nl", "fi", "fr", "fr-CA", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "ko", "ms", "ml", "mr", "nb", "or", "pl", "pt-BR", "pt-PT", "pa", "ro", "ru", "sk", "sl", "es", "es-419", "sv", "ta", "te", "th", "tr", "uk", "ur", "vi":
            return true
        default:
            return false
        }
    }
}
