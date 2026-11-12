#if os(macOS)
import AppKit
import PDFKit
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Services/PagePaginator.cs: when Lazy Print is not there the document is printed from the
// same pages the viewer draws. A page larger than the paper is shrunk to fit and a smaller one keeps its size, which is
// PDFKit's scale-down mode. Pages are not turned to fit the paper, as the Windows paginator does not turn them.

@MainActor
enum MacSystemPrint {
    /// Nil when neither PDFKit nor the engine can read the file, or it is locked and `password` does not open it.
    static func operation(_ session: PdfEditSession, password: String?, title: String, info: NSPrintInfo = NSPrintInfo.shared) -> NSPrintOperation? {
        guard let document = document(session, password) else { return nil }
        let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: false)
        operation?.jobTitle = title
        return operation
    }

    /// As above for the pages a layout leaves, laid out on sheets of the paper in `info` when it asks for a booklet. The
    /// count is of the annotations the sheets could not take. Nil also when the layout leaves no page or the sheets cannot
    /// be made.
    static func operation(_ session: PdfEditSession, password: String?, title: String, layout: PrintLayout,
                          info: NSPrintInfo = NSPrintInfo.shared) -> (operation: NSPrintOperation, dropped: Int)? {
        let info = info.copy() as? NSPrintInfo ?? info
        if layout.booklet { info.orientation = .landscape }
        guard !layout.pages(count: session.document.pages.count).isEmpty,
              let sheets = try? layout.file(session.document, sheetWidth: info.paperSize.width, sheetHeight: info.paperSize.height),
              let made = try? PdfEditSession.open(sheets.bytes),
              let document = layout.imposes ? PDFDocument(data: Data(sheets.bytes)) : MacSystemPrint.document(made, nil) else { return nil }
        let operation = document.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: false)
        operation?.jobTitle = title
        return operation.map { ($0, sheets.dropped) }
    }

    // PDFKit prints a /UserUnit 2 page at the size of /UserUnit 1, so such pages are drawn into a new document at their
    // real size, which keeps them vector.
    static func document(_ session: PdfEditSession, _ password: String?) -> PDFDocument? {
        guard let document = PdfKitRenderer.document(session, password) else { return nil }
        let pages = session.document.pages
        let units = (0..<document.pageCount).map { $0 < pages.count ? pages[$0].userUnit : 1 }
        return units.allSatisfy { $0 == 1 } ? document : scaled(document, units) ?? document
    }

    private static func scaled(_ document: PDFDocument, _ units: [Double]) -> PDFDocument? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        for (i, unit) in units.enumerated() {
            guard let page = document.page(at: i) else { return nil }
            let box = page.bounds(for: .cropBox)
            let turned = abs(page.rotation) % 180 == 90
            let size = CGSize(width: turned ? box.height : box.width, height: turned ? box.width : box.height)
            var media = CGRect(x: 0, y: 0, width: size.width * unit, height: size.height * unit)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.scaleBy(x: unit, y: unit)
            context.clip(to: CGRect(origin: .zero, size: size))
            page.draw(with: .cropBox, to: context)
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }
}
#endif
