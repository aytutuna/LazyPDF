import Foundation

// Twin of windows/LazyPDF.Core/Document/IPageRenderer.cs: draws the pages of one open file. PDFKit does this on
// Apple; an app makes one per document it hands to the engine.

public protocol PageRenderer: AnyObject {
    /// The page as displayed, /Rotate and crop box applied, at `dpi`. Nil when the system cannot draw it.
    func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage?
}
