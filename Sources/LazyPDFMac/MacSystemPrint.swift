#if os(macOS)
import AppKit
import PDFKit

// Follows windows/LazyPDF.App/Services/PagePaginator.cs: when Lazy Print is not there the document is printed from its
// current bytes. A page larger than the paper is shrunk to fit and a smaller one keeps its size, which is PDFKit's
// scale-down mode.

@MainActor
enum MacSystemPrint {
    /// Nil when PDFKit cannot read the file, or it is locked and `password` does not open it.
    static func operation(_ bytes: [UInt8], password: String?, info: NSPrintInfo = NSPrintInfo.shared) -> NSPrintOperation? {
        guard let document = PDFDocument(data: Data(bytes)) else { return nil }
        if document.isLocked, !document.unlock(withPassword: password ?? "") { return nil }
        return document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: true)
    }
}
#endif
