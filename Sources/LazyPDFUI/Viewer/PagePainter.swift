#if canImport(SwiftUI)
import CoreGraphics
import CoreText
import Foundation
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageSurface.Draw.cs and the Decorate half of PageViewer.Text.cs: for each page in view its
// paper, the best pictures there are, then the search hits and the selection, then the marks of the tools. Nothing here waits for a tile; what has not come
// is drawn from a smaller one. The context is y down and in the viewer's view space, as both platforms' views set it up.

/// What the painter takes from the platform's colours.
struct PageColors {
    var edge: CGColor
    var selection: CGColor
    var mark: CGColor
    var failure: CGColor
    var showsHandles = false
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
        let area = ViewRect(dirty.minX, dirty.minY, dirty.width, dirty.height)
        for page in viewer.pages(in: area) {
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
            let drawing = viewer.drawing(of: page, in: area)
            for picture in drawing.pictures {
                if let image = image(of: picture.picture) {
                    draw(image, in: CGRect(picture.rect), turned: viewer.rotation, sharp: !picture.isPreview, context)
                }
            }
            if drawing.failed {
                drawFailure(L10n.t("This page cannot be shown."), atBottom: false, in: rect, colors, context)
            } else if drawing.partFailed {
                drawFailure(L10n.t("Part of this page could not be drawn sharply."), atBottom: true, in: rect.intersection(CGRect(x: 0, y: 0, width: viewer.viewport.width, height: viewer.viewport.height)), colors, context)
            }
            highlight(viewer, page, matrix, colors, context)
            OverlayPainter.draw(viewer.overlay(page), matrix: matrix, accent: colors.mark, in: context)
            context.restoreGState()
        }
        if let placement = viewer.placement, let matrix = viewer.pageToView(placement.page) {
            drawMark(at: matrix.transform(placement.point), colors, context)
        }
        if colors.showsHandles, let handles = viewer.selectionHandles() {
            drawHandle(at: handles.start, colors, context)
            drawHandle(at: handles.end, colors, context)
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
    private static func draw(_ image: CGImage, in rect: CGRect, turned rotation: Int, sharp: Bool, _ context: CGContext) {
        context.saveGState()
        if sharp { context.setShouldAntialias(false) }
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: CGFloat(rotation) * .pi / 180)
        context.scaleBy(x: 1, y: -1)
        let upright = rotation == 90 || rotation == 270 ? CGSize(width: rect.height, height: rect.width) : rect.size
        if sharp {
            let across = context.convertToDeviceSpace(CGSize(width: upright.width, height: 0))
            let down = context.convertToDeviceSpace(CGSize(width: 0, height: upright.height))
            if Int(hypot(across.width, across.height).rounded()) == image.width && Int(hypot(down.width, down.height).rounded()) == image.height {
                context.interpolationQuality = .none
            }
        }
        context.draw(image, in: CGRect(x: -upright.width / 2, y: -upright.height / 2, width: upright.width, height: upright.height))
        context.restoreGState()
    }

    private static func drawFailure(_ message: String, atBottom: Bool, in page: CGRect, _ colors: PageColors, _ context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colors.failure,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: message, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let y = atBottom ? page.maxY - descent - 8 : page.minY + Swift.min(page.height / 2, 120)
        context.textPosition = CGPoint(x: page.midX - width / 2, y: y)
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

    // A stem up from the baseline with a ball on its free end, as a touch selection has at each end.
    private static func drawHandle(at point: ViewPoint, _ colors: PageColors, _ context: CGContext) {
        context.saveGState()
        context.setStrokeColor(colors.mark)
        context.setFillColor(colors.mark)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: point.x, y: point.y))
        context.addLine(to: CGPoint(x: point.x, y: point.y - 14))
        context.strokePath()
        context.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 19, width: 10, height: 10))
        context.restoreGState()
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
