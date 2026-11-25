import Foundation
import LazyPDFKit

/// Draws pages for the recognizer at no more pixels than `maxPixels`, so a poster-sized page does not take a gigabyte of
/// bitmap; the recognizer reads it at a lower resolution instead.
public final class OcrRenderer: PageRenderer {
    public static let maxPixels = 40_000_000

    private let renderer: DocumentRenderer

    public init(_ renderer: DocumentRenderer) {
        self.renderer = renderer
    }

    public func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        let size = renderer.pageSize(pageIndex)
        return renderer.render(pageIndex, Self.cappedDpi(size.width, size.height, dpi))
    }

    static func cappedDpi(_ width: Double, _ height: Double, _ dpi: Double) -> Double {
        let pixels = width * dpi / 72 * (height * dpi / 72)
        guard pixels > Double(maxPixels) else { return dpi }
        return dpi * (Double(maxPixels) / pixels).squareRoot()
    }
}
