import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/TimedOutText.cs: says which pages a pattern ran out of time on.
public enum TimedOutText {
    private static let listed = 5

    /// Takes 0-based page indexes, ascending; nil when there are none.
    public static func forPages(_ pages: [Int]) -> String? {
        if pages.isEmpty { return nil }
        if pages.count == 1 { return L10n.t("The pattern took too long on page {0}; it was not searched.", pages[0] + 1) }
        if pages.count > listed {
            return L10n.t("The pattern took too long on {0} pages, the first being page {1}; they were not searched.", pages.count, pages[0] + 1)
        }
        let list = L10n.t("{0} and {1}", pages.dropLast().map { String($0 + 1) }.joined(separator: ", "), pages[pages.count - 1] + 1)
        return L10n.t("The pattern took too long on pages {0}; they were not searched.", list)
    }
}
