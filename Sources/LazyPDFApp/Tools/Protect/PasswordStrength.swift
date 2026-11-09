import Foundation

// Follows windows/LazyPDF.App/Tools/Protect/PasswordStrength.cs.

public enum PasswordRating: Int, Comparable {
    case none, weak, fair, good, strong

    public static func < (a: PasswordRating, b: PasswordRating) -> Bool { a.rawValue < b.rawValue }
}

public enum PasswordStrength {
    private static let common = ["password", "123456", "qwerty", "letmein", "iloveyou", "admin", "welcome", "parola", "sifre", "1234567890", "abcdef"]

    public static func rate(_ password: String) -> PasswordRating {
        if password.isEmpty { return .none }
        let rest = common.reduce(password.lowercased()) { $0.replacingOccurrences(of: $1, with: "") }
        if Set(password).count < 5 || Set(rest).count < 5 { return .weak }

        var points = [8, 12, 16, 20].filter { password.utf16.count >= $0 }.count
        let kinds = [password.contains { $0.isLowercase }, password.contains { $0.isUppercase },
                     password.contains { $0.isWholeNumber && $0.isNumber }, password.contains { !($0.isLetter || $0.isNumber) }]
        if kinds.filter({ $0 }).count >= 3 { points += 1 }
        switch points {
        case ...1: return .weak
        case 2: return .fair
        case 3: return .good
        default: return .strong
        }
    }

    public static func hint(_ strength: PasswordRating) -> String {
        switch strength {
        case .none: return ""
        case .weak: return L10n.t("Weak. Try 12 or more characters.")
        case .fair: return L10n.t("Fair. A longer one is safer.")
        case .good: return L10n.t("Good.")
        case .strong: return L10n.t("Strong.")
        }
    }
}
