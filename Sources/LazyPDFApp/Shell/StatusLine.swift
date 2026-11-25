import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/StatusLine.cs: the status line shows at most six words of the status sentence,
// facts only, and the whole sentence stays the line's accessible name.

public enum StatusLine {
    public static let maxWords = 6

    /// Words as the text spec counts them: whitespace-separated tokens with a letter or digit.
    public static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter(isWord).count
    }

    /// The first sentence of `message`, cut at a dash, colon or comma when it is longer than six words.
    public static func short(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        let first = firstSentence(text)
        if words(first) <= maxWords { return first }
        for mark in [" \u{2014} ", ": ", ", "] {
            if let at = first.range(of: mark), at.lowerBound > first.startIndex, words(String(first[..<at.lowerBound])) <= maxWords {
                return String(first[..<at.lowerBound])
            }
        }
        var kept: [Substring] = []
        var count = 0
        for token in first.split(separator: " ") {
            if isWord(token) {
                count += 1
                if count > maxWords { break }
            }
            kept.append(token)
        }
        let line = kept.joined(separator: " ")
        return String(line.reversed().drop(while: { ",:;. ".contains($0) }).reversed()) + "\u{2026}"
    }

    /// The page's own label when the file has one that differs from its number.
    public static func page(label: String, index: Int, count: Int) -> String {
        label == String(index + 1) ? L10n.t("Page {0} of {1}", index + 1, count) : L10n.t("Page {0} ({1} of {2})", label, index + 1, count)
    }

    public static func size(widthPt: Double, heightPt: Double, metric: Bool) -> String {
        if metric {
            return L10n.t("{0} × {1} mm", (widthPt * 25.4 / 72).rounded(), (heightPt * 25.4 / 72).rounded())
        }
        return L10n.t("{0} × {1} in", (widthPt / 72 * 10).rounded() / 10, (heightPt / 72 * 10).rounded() / 10)
    }

    private static func isWord(_ token: Substring) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }

    // The first sentence without its full stop ("…" is kept: it says work is under way).
    private static func firstSentence(_ text: String) -> String {
        let chars = Array(text)
        if chars.count > 2 {
            for i in 0..<(chars.count - 2) where ".!?".contains(chars[i]) && chars[i + 1] == " " && (chars[i + 2].isUppercase || chars[i + 2].isNumber) {
                return String(chars[..<i])
            }
        }
        return text.hasSuffix(".") && !text.hasSuffix("\u{2026}") ? String(text.dropLast()) : text
    }
}
