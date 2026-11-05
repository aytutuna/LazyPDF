import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportPdf.cs: what the PDFs made from pictures and from text start from.

enum ExportPdf {
    private static let a4Width = 595.276, a4Height = 841.89
    private static let letterWidth = 612.0, letterHeight = 792.0

    // A file of a catalog and an empty tree, with a proper table so that opening it needs no repair.
    static func newDocument() throws -> PdfDocument {
        let head = "%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n"
        let catalog = "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n"
        let tree = "2 0 obj\n<</Type /Pages /Kids [] /Count 0>>\nendobj\n"
        let first = head.unicodeScalars.count, second = first + catalog.unicodeScalars.count, table = second + tree.unicodeScalars.count
        let end = "xref\n0 3\n0000000000 65535 f \n" + String(format: "%010ld", first) + " 00000 n \n" + String(format: "%010ld", second)
            + " 00000 n \ntrailer\n<</Size 3 /Root 1 0 R>>\nstartxref\n\(table)\n%%EOF\n"
        return try PdfDocument.open(Latin1.bytes(head + catalog + tree + end))
    }

    /// A4 or Letter in portrait, turned when landscape. `PdfPaper.picture` reads as A4.
    static func paper(_ setup: PdfPageSetup, landscape: Bool) -> (width: Double, height: Double) {
        let (w, h) = setup.paper == .letter ? (letterWidth, letterHeight) : (a4Width, a4Height)
        var turned = landscape
        switch setup.orientation {
        case .portrait: turned = false
        case .landscape: turned = true
        case .auto: break
        }
        return turned ? (h, w) : (w, h)
    }
}
