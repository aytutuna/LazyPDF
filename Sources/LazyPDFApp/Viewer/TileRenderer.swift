import Foundation
import LazyPDFKit

// Draws the tiles of windows/LazyPDF.App/Viewer/PageSurface.Tiles.cs: DrawAsync there, WindowsPageRenderer.RenderTileAsync behind it.

/// A renderer that can draw a rectangle of a page without drawing the rest.
public protocol TileRenderer: DocumentRenderer {
    /// The rectangle at (`x`, `y`) of `width` by `height` pixels in the pixels of the whole page at `pixelsPerPoint`.
    func renderTile(_ pageIndex: Int, _ pixelsPerPoint: Double, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> PdfRgbaImage?
}

#if canImport(PDFKit)
extension PdfKitRenderer: TileRenderer {}
#endif

/// Draws tiles from whichever renderer is current: the tab's, or the display copy's while layers are switched. The
/// scheduler's workers call it from tasks of their own.
final class TileDrawer: @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: DocumentRenderer?

    func use(_ renderer: DocumentRenderer?) {
        lock.lock()
        self.renderer = renderer
        lock.unlock()
    }

    func draw(_ spec: TileSpec) -> PdfRgbaImage? {
        lock.lock()
        let renderer = self.renderer
        lock.unlock()
        guard let renderer else { return nil }
        let key = spec.key
        if key.isPreview { return renderer.render(key.page, key.scale * 72) }
        if let tiles = renderer as? TileRenderer {
            return tiles.renderTile(key.page, key.scale, spec.x, spec.y, spec.width, spec.height)
        }
        // A renderer with no tiles draws the page whole and the tile is cut out of it.
        guard let page = renderer.render(key.page, key.scale * 72) else { return nil }
        return Self.cut(page, spec)
    }

    static func cut(_ page: PdfRgbaImage, _ spec: TileSpec) -> PdfRgbaImage {
        var rgba = [UInt8](repeating: 255, count: spec.width * spec.height * 4)
        for row in 0..<spec.height {
            let y = spec.y + row
            if y < 0 || y >= page.height { continue }
            let from = Swift.max(0, spec.x), to = Swift.min(page.width, spec.x + spec.width)
            if from >= to { continue }
            let source = (y * page.width + from) * 4
            let target = (row * spec.width + from - spec.x) * 4
            rgba.replaceSubrange(target..<(target + (to - from) * 4), with: page.rgba[source..<(source + (to - from) * 4)])
        }
        return PdfRgbaImage(spec.width, spec.height, rgba)
    }
}

/// A finished tile in the cache. The view keeps its own picture of the bitmap in `native`, made on first draw, so it lives
/// and goes with the cache entry.
public final class TilePicture: PixelSized {
    public let bitmap: TileBitmap
    public var native: AnyObject?

    init(_ bitmap: TileBitmap) {
        self.bitmap = bitmap
    }

    public var pixelWidth: Int { bitmap.pixelWidth }
    public var pixelHeight: Int { bitmap.pixelHeight }
}

/// A picture to draw and the rectangle of the viewer's view it goes in, snapped to device pixels.
public struct PagePicture {
    public let picture: TilePicture
    public let rect: ViewRect
}

/// What to draw for one page: its pictures, oldest and smallest first, and whether it could not be drawn at all.
public struct PageDrawing {
    public let pictures: [PagePicture]
    public let failed: Bool
}
