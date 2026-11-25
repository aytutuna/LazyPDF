import Foundation

// Twin of windows/LazyPDF.Core/Export/ExportPdf.cs: what the PDFs made from pictures and from text start from.

public enum ExportPdf {
    private static let a4Width = 595.276, a4Height = 841.89
    private static let letterWidth = 612.0, letterHeight = 792.0
    private static let a3Width = 841.89, a3Height = 1190.551
    private static let a5Width = 419.528, a5Height = 595.276
    private static let legalHeight = 1008.0
    private static let minSide = 3.0, maxSide = 14400.0

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

    /// The paper in portrait, turned when landscape. `PdfPaper.picture` reads as A4.
    public static func paper(_ setup: PdfPageSetup, landscape: Bool) -> (width: Double, height: Double) {
        let (w, h): (Double, Double)
        switch setup.paper {
        case .letter: (w, h) = (letterWidth, letterHeight)
        case .a3: (w, h) = (a3Width, a3Height)
        case .a5: (w, h) = (a5Width, a5Height)
        case .legal: (w, h) = (letterWidth, legalHeight)
        case .custom: (w, h) = (min(side(setup.customWidth), side(setup.customHeight)), max(side(setup.customWidth), side(setup.customHeight)))
        case .a4, .picture: (w, h) = (a4Width, a4Height)
        }
        var turned = landscape
        switch setup.orientation {
        case .portrait: turned = false
        case .landscape: turned = true
        case .auto: break
        }
        return turned ? (h, w) : (w, h)
    }

    private static func side(_ value: Double) -> Double { value.isNaN ? minSide : min(max(value, minSide), maxSide) }
}
