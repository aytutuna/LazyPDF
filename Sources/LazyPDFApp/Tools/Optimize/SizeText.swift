import Foundation

// Follows windows/LazyPDF.App/Tools/Optimize/SizeText.cs.

public enum SizeText {
    public static func of(_ bytes: Int) -> String {
        if bytes < 1024 { return L10n.t("{0} bytes", bytes) }
        if bytes < 1024 * 1024 { return L10n.t("{0} KB", rounded(Double(bytes) / 1024)) }
        return L10n.t("{0} MB", rounded(Double(bytes) / 1_048_576))
    }

    public static func percent(_ before: Int, _ after: Int) -> Int {
        before <= 0 ? 0 : Int((100.0 * Double(before - after) / Double(before)).rounded())
    }

    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
