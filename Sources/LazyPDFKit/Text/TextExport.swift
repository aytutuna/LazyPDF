import Foundation

// Twin of windows/LazyPDF.Core/Text/TextExport.cs: plain text of pages.

public enum TextExport {
    /// The text of one page; see `TextPage.getText` for what `joinHyphens` does.
    public static func page(_ page: TextPage, joinHyphens: Bool = false) -> String {
        page.getText(TextRange(0, page.chars.count), joinHyphens: joinHyphens)
    }

    /// The pages `first` to `last` (0-based, inclusive), each followed by a form feed as `pdftotext` writes them.
    public static func range(_ cache: TextCache, _ first: Int, _ last: Int, joinHyphens: Bool = false) throws -> String {
        var result = ""
        var p = max(first, 0)
        let end = min(last, cache.pageCount - 1)
        while p <= end {
            try Task.checkCancellation()
            result += page(cache.get(p), joinHyphens: joinHyphens)
            result += "\u{0C}"
            p += 1
        }
        return result
    }
}
