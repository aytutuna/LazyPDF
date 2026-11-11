#if canImport(PDFKit)
import CoreGraphics
import Foundation
import LazyPDFKit
import PDFKit

// Follows windows/LazyPDF.App/Services/WindowsPageRenderer.cs (and Pixels.cs, which has no work to do here: the pixels
// are drawn straight into RGBA). The pages of one document drawn by PDFKit from the session's current bytes, loaded
// again after every commit.
//
// A file PDFKit refuses (public-key encryption, a password it will not take) is decrypted by the engine first, only
// for drawing. PDFKit takes any pixel size, so there is nothing to round as WindowsPageRenderer.Reachable does.
// The sizes are in the units the viewer lays out, /UserUnit applied. PDFKit draws a page of /UserUnit 2 at the size
// of /UserUnit 1, as Windows does, so the unit is applied here (PdfKitRendererTests checks it on the real thing).
// Safe to call from any thread: PDFKit is not documented as thread safe, so drawing is serialized per document, and
// a load that is replaced finishes the pictures already being drawn on the old one.

public final class PdfKitRenderer: DocumentRenderer {
    private static let maxPixels = 150_000_000

    private final class Loaded {
        let document: PDFDocument
        let sizes: [(width: Double, height: Double)]
        let units: [Double]
        let gate = NSLock()

        init(_ document: PDFDocument, _ units: [Double]) {
            self.document = document
            self.units = units
            sizes = (0..<document.pageCount).map { i -> (width: Double, height: Double) in
                let unit = i < units.count ? units[i] : 1
                guard let page = document.page(at: i) else { return (0, 0) }
                let box = page.bounds(for: .cropBox)
                let turned = abs(page.rotation) % 180 == 90
                return ((turned ? box.height : box.width) * unit, (turned ? box.width : box.height) * unit)
            }
        }
    }

    private let lock = NSLock()
    private var loaded: Loaded?

    public init() {}

    private var current: Loaded? {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    public var pageCount: Int { current?.sizes.count ?? 0 }

    public func pageSize(_ pageIndex: Int) -> (width: Double, height: Double) {
        guard let loaded = current, loaded.sizes.indices.contains(pageIndex) else { return (0, 0) }
        return loaded.sizes[pageIndex]
    }

    public func load(_ session: PdfEditSession, _ password: String?) -> Bool {
        let source = session.document
        let document = Self.document(session, password)
        let pages = source.pages
        let units = (0..<(document?.pageCount ?? 0)).map { $0 < pages.count ? pages[$0].userUnit : 1 }
        let next = document.map { Loaded($0, units) }
        lock.lock()
        loaded = next
        lock.unlock()
        return next != nil
    }

    /// What PDFKit draws or prints for the session: its current bytes, or the engine's decrypted copy when PDFKit refuses them.
    public static func document(_ session: PdfEditSession, _ password: String?) -> PDFDocument? {
        let source = session.document
        var document: PDFDocument?
        if !source.isEncrypted || source.security.map({ !$0.isPublicKey && $0.revision < 6 }) == true {
            document = open(session.current, password)
        }
        if document == nil, source.isEncrypted {
            // Only for drawing: the copy is never saved, so the permissions on changing the encryption do not apply.
            if let copy = try? PdfRewriter(source, PdfSaveOptions()).run() { document = open(copy, nil) }
        }
        return document
    }

    public func close() {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    private static func open(_ bytes: [UInt8], _ password: String?) -> PDFDocument? {
        guard let document = PDFDocument(data: Data(bytes)) else { return nil }
        if document.isLocked, !document.unlock(withPassword: password ?? "") { return nil }
        return document.pageCount > 0 ? document : nil
    }

    public func render(_ pageIndex: Int, _ dpi: Double) -> PdfRgbaImage? {
        let (width, height) = pageSize(pageIndex)
        guard width > 0, height > 0, dpi > 0 else { return nil }
        return draw(pageIndex, DisplayRect(0, 0, width, height), Self.pixels(width * dpi / 72), Self.pixels(height * dpi / 72))
    }

    /// A rectangle of the page, in points of the displayed page with the origin at its top left, drawn at `dpi`.
    /// Outside the page it is white.
    public func renderRegion(_ pageIndex: Int, _ region: DisplayRect, _ dpi: Double) -> PdfRgbaImage? {
        guard region.width > 0, region.height > 0, dpi > 0 else { return nil }
        return draw(pageIndex, region, Self.pixels(region.width * dpi / 72), Self.pixels(region.height * dpi / 72))
    }

    /// The rectangle at (`x`, `y`) of `width` by `height` pixels in the pixels of the whole page at `pixelsPerPoint`.
    /// Tiles cut on whole pixels meet exactly.
    public func renderTile(_ pageIndex: Int, _ pixelsPerPoint: Double, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> PdfRgbaImage? {
        guard width > 0, height > 0, pixelsPerPoint > 0 else { return nil }
        let region = DisplayRect(Double(x) / pixelsPerPoint, Double(y) / pixelsPerPoint, Double(width) / pixelsPerPoint, Double(height) / pixelsPerPoint)
        return draw(pageIndex, region, width, height)
    }

    private static func pixels(_ value: Double) -> Int {
        value.isFinite ? Int(min(max(value.rounded(), 1), Double(Int32.max))) : 0
    }

    private func draw(_ pageIndex: Int, _ region: DisplayRect, _ width: Int, _ height: Int) -> PdfRgbaImage? {
        guard let loaded = current, loaded.sizes.indices.contains(pageIndex), width > 0, height > 0,
              width <= Self.maxPixels / height else { return nil }
        let unit = loaded.units.indices.contains(pageIndex) ? loaded.units[pageIndex] : 1
        let (shownWidth, shownHeight) = loaded.sizes[pageIndex]
        // PDFKit's own points: the viewer's divided by the unit.
        let whole = (width: shownWidth / unit, height: shownHeight / unit)
        let area = (x: region.x / unit, y: region.y / unit, width: region.width / unit, height: region.height / unit)

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.scaleBy(x: Double(width) / area.width, y: Double(height) / area.height)
            // The context has its origin at the bottom left, the region at the top left.
            context.translateBy(x: -area.x, y: -(whole.height - area.y - area.height))
            context.clip(to: CGRect(x: 0, y: 0, width: whole.width, height: whole.height))
            loaded.gate.lock()
            defer { loaded.gate.unlock() }
            guard let page = loaded.document.page(at: pageIndex) else { return false }
            page.draw(with: .cropBox, to: context)
            return true
        }
        // The buffer started white and opaque, so premultiplied and straight alpha are the same bytes.
        return drawn ? PdfRgbaImage(width, height, rgba) : nil
    }
}
#endif
