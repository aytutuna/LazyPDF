#if canImport(SwiftUI)
import CoreGraphics
import CoreText
import Foundation
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageSurface.Draw.cs and the Decorate half of PageViewer.Text.cs: for each page in view its
// paper, the best pictures there are, then the search hits and the selection. Nothing here waits for a tile; what has not come
// is drawn from a smaller one. The context is y down and in the viewer's view space, as both platforms' views set it up.

/// What the painter takes from the platform's colours.
struct PageColors {
    var edge: CGColor
    var selection: CGColor
    var mark: CGColor
    var failure: CGColor
}

enum PagePainter {
    static let hit = CGColor(srgbRed: 1, green: 214.0 / 255, blue: 0, alpha: 110.0 / 255)
    static let currentHit = CGColor(srgbRed: 1, green: 140.0 / 255, blue: 0, alpha: 160.0 / 255)
    private static let shadow = CGColor(gray: 0, alpha: 18.0 / 255)

    @MainActor
    static func draw(_ viewer: ViewerModel, in context: CGContext, dirty: CGRect, colors: PageColors) {
        let paper = PageTints.paper(viewer.tint)
        let paperColor = CGColor(srgbRed: CGFloat(paper.red) / 255, green: CGFloat(paper.green) / 255, blue: CGFloat(paper.blue) / 255, alpha: 1)
        context.interpolationQuality = .high
        for page in viewer.visiblePages {
            guard let matrix = viewer.pageToView(page) else { continue }
            let size = viewer.pageSize(page)
            let rect = CGRect(PageSpace.transform(matrix, ViewRect(0, 0, size.width, size.height)))
            if !rect.intersects(dirty) { continue }
            context.saveGState()
            context.setFillColor(shadow)
            context.fill(CGRect(x: rect.minX - 1.5, y: rect.minY - 0.5, width: rect.width + 3, height: rect.height + 4))
            context.setFillColor(paperColor)
            context.fill(rect)
            context.setStrokeColor(colors.edge)
            context.setLineWidth(1)
            context.stroke(rect)
            context.clip(to: rect.intersection(dirty))
            let drawing = viewer.drawing(of: page)
            for picture in drawing.pictures {
                if let image = image(of: picture.picture) {
                    draw(image, in: CGRect(picture.rect), turned: viewer.rotation, context)
                }
            }
            if drawing.failed { drawFailure(in: rect, dark: viewer.tint == .dark, colors, context) }
            highlight(viewer, page, matrix, colors, context)
            context.restoreGState()
        }
        if let placement = viewer.placement, let matrix = viewer.pageToView(placement.page) {
            drawMark(at: matrix.transform(placement.point), colors, context)
        }
    }

    // The picture of a tile is made when it is first drawn and goes with the cache entry.
    private static func image(of picture: TilePicture) -> CGImage? {
        if let made = picture.native { return (made as! CGImage) }
        guard let image = picture.bitmap.cgImage else { return nil }
        picture.native = image
        return image
    }

    // The picture is of the page upright; it is turned about its own centre into the rectangle the matrix gave. A Core Graphics
    // image is drawn with its bottom up, which a y down context shows upside down, so it is flipped back.
    private static func draw(_ image: CGImage, in rect: CGRect, turned rotation: Int, _ context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(rotation) * .pi / 180)
        context.scaleBy(x: 1, y: -1)
        let upright = rotation == 90 || rotation == 270 ? CGSize(width: rect.height, height: rect.width) : rect.size
        context.draw(image, in: CGRect(x: -upright.width / 2, y: -upright.height / 2, width: upright.width, height: upright.height))
        context.restoreGState()
    }

    private static func drawFailure(in page: CGRect, dark: Bool, _ colors: PageColors, _ context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colors.failure,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: L10n.t("This page cannot be shown."), attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: page.midX - width / 2, y: page.minY + Swift.min(page.height / 2, 120))
        CTLineDraw(line, context)
        context.restoreGState()
    }

    @MainActor
    private static func highlight(_ viewer: ViewerModel, _ page: Int, _ matrix: ViewMatrix, _ colors: PageColors, _ context: CGContext) {
        let shapes = viewer.highlights(of: page)
        if shapes.hits.isEmpty && shapes.currentHit.isEmpty && shapes.selection.isEmpty { return }
        context.saveGState()
        context.concatenate(CGAffineTransform(a: matrix.m11, b: matrix.m12, c: matrix.m21, d: matrix.m22, tx: matrix.offsetX, ty: matrix.offsetY))
        fill(shapes.hits, hit, context)
        fill(shapes.currentHit, currentHit, context)
        fill(shapes.selection, colors.selection, context)
        context.restoreGState()
    }

    private static func fill(_ polygons: [[ViewPoint]], _ color: CGColor, _ context: CGContext) {
        if polygons.isEmpty { return }
        context.beginPath()
        for polygon in polygons {
            context.addLines(between: polygon.map { CGPoint(x: $0.x, y: $0.y) })
            context.closePath()
        }
        context.setFillColor(color)
        context.fillPath()
    }

    // The cross a keyboard placement stands on.
    private static func drawMark(at point: ViewPoint, _ colors: PageColors, _ context: CGContext) {
        context.saveGState()
        context.setStrokeColor(colors.mark)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: point.x - 9, y: point.y))
        context.addLine(to: CGPoint(x: point.x + 9, y: point.y))
        context.move(to: CGPoint(x: point.x, y: point.y - 9))
        context.addLine(to: CGPoint(x: point.x, y: point.y + 9))
        context.strokePath()
        context.restoreGState()
    }
}

extension CGRect {
    init(_ rect: ViewRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
#endif
