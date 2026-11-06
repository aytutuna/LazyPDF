import Foundation

// Twin of windows/LazyPDF.Core/Compare/PdfComparer.cs: compares two PDF files by what they say: pages are paired by the
// similarity of their text, then the words, fonts, pictures and annotations of each pair are compared, and the metadata,
// bookmarks, attachments and form values of the files. Drawings made of paths are not compared; use `PixelComparer` for
// those. A text that has no Unicode mapping in its font cannot be compared.

public enum PdfComparer {
    /// Throws `CancellationError` when the task is cancelled; the C# CancellationToken is the task's.
    public static func compare(_ before: PdfDocument, _ after: PdfDocument, _ options: CompareOptions? = nil) throws -> ComparisonResult {
        try Comparison(before, after, options ?? CompareOptions()).run()
    }
}
