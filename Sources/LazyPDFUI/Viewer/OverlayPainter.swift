#if canImport(SwiftUI)
import CoreGraphics
import CoreText
import Foundation
import LazyPDFApp
import LazyPDFKit

// Paints the marks of a PageOverlay (windows/LazyPDF.App/Viewer/PageSurface.Overlays.cs). The context is y down and in the
// viewer's view space, already clipped to the page; the page matrix is applied here, so marks are in page space and turn with
// the page. Sizes that must not grow with the zoom are divided by the matrix's scale.

enum OverlayPainter {
    @MainActor
    static func draw(_ overlay: PageOverlay, matrix: ViewMatrix, accent: CGColor, in context: CGContext) {
        let items = overlay.painted
        if items.isEmpty { return }
        let scale = (matrix.m11 * matrix.m11 + matrix.m12 * matrix.m12).squareRoot()
        if scale <= 0 { return }
        context.saveGState()
        context.concatenate(CGAffineTransform(a: matrix.m11, b: matrix.m12, c: matrix.m21, d: matrix.m22, tx: matrix.offsetX, ty: matrix.offsetY))
        let paint = Paint(accent: accent, scale: scale)
        for item in items { draw(item, paint, context) }
        context.restoreGState()
    }

    private struct Paint {
        let accent: CGColor
        let scale: Double

        func color(_ color: OverlayColor, _ opacity: Double) -> CGColor {
            let alpha = CGFloat(color.alpha * opacity)
            if color.isAccent { return accent.copy(alpha: alpha) ?? accent }
            return CGColor(srgbRed: CGFloat(color.red), green: CGFloat(color.green), blue: CGFloat(color.blue), alpha: alpha)
        }

        // Screen points or page points, as the style says, in page points.
        func length(_ value: Double, _ style: OverlayStyle) -> CGFloat {
            CGFloat(style.scalesWithPage ? value : value / scale)
        }
    }

    private static func draw(_ item: OverlayItem, _ paint: Paint, _ context: CGContext) {
        context.saveGState()
        if item.rotation != 0 {
            let pivot = item.pivot ?? self.pivot(of: item.shape)
            context.translateBy(x: pivot.x, y: pivot.y)
            context.rotate(by: CGFloat(item.rotation) * .pi / 180)
            context.translateBy(x: -pivot.x, y: -pivot.y)
        }
        let style = item.style
        switch item.shape {
        case .rect(let area):
            let rect = CGRect(area)
            if let fill = style.fill {
                context.setFillColor(paint.color(fill, item.opacity))
                context.fill(rect)
            }
            if stroke(style, item.opacity, paint, context) { context.stroke(rect) }
        case .ellipse(let area):
            let rect = CGRect(area)
            if let fill = style.fill {
                context.setFillColor(paint.color(fill, item.opacity))
                context.fillEllipse(in: rect)
            }
            if stroke(style, item.opacity, paint, context) { context.strokeEllipse(in: rect) }
        case .line(let from, let to):
            if stroke(style, item.opacity, paint, context) {
                context.move(to: CGPoint(x: from.x, y: from.y))
                context.addLine(to: CGPoint(x: to.x, y: to.y))
                context.strokePath()
            }
        case .path(let points, let closed):
            path(points, closed: closed, style, item.opacity, paint, context)
        case .marker(let center, let size, let round):
            let side = CGFloat(size / paint.scale)
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            if let fill = style.fill {
                context.setFillColor(paint.color(fill, item.opacity))
                if round { context.fillEllipse(in: rect) } else { context.fill(rect) }
            }
            if stroke(style, item.opacity, paint, context) {
                if round { context.strokeEllipse(in: rect) } else { context.stroke(rect) }
            }
        case .text(let text):
            draw(text, item.opacity, paint, context)
        case .picture(let picture):
            draw(picture, item.opacity, context)
        }
        context.restoreGState()
    }

    // The middle of a rectangle, an ellipse or a picture; the anchor of a text; the first point of anything else.
    private static func pivot(of shape: OverlayShape) -> ViewPoint {
        switch shape {
        case .rect(let area), .ellipse(let area): return area.center
        case .picture(let picture): return picture.rect.center
        case .text(let text): return text.at
        case .line(let from, _): return from
        case .path(let points, _): return points.first ?? .zero
        case .marker(let center, _, _): return center
        }
    }

    // Sets the stroke of the style on the context; false when it has none.
    private static func stroke(_ style: OverlayStyle, _ opacity: Double, _ paint: Paint, _ context: CGContext) -> Bool {
        guard let color = style.stroke else { return false }
        context.setStrokeColor(paint.color(color, opacity))
        context.setLineWidth(paint.length(style.lineWidth, style))
        context.setLineCap(style.round ? .round : .butt)
        context.setLineJoin(style.round ? .round : .miter)
        context.setLineDash(phase: 0, lengths: style.dash.map { paint.length($0, style) })
        return true
    }

    private static func path(_ points: [ViewPoint], closed: Bool, _ style: OverlayStyle, _ opacity: Double, _ paint: Paint, _ context: CGContext) {
        if points.count < 2 { return }
        let made = CGMutablePath()
        made.addLines(between: points.map { CGPoint(x: $0.x, y: $0.y) })
        if closed { made.closeSubpath() }
        if let fill = style.fill, closed {
            context.addPath(made)
            context.setFillColor(paint.color(fill, opacity))
            context.fillPath()
        }
        if stroke(style, opacity, paint, context) {
            context.addPath(made)
            context.strokePath()
        }
    }

    private static func draw(_ picture: OverlayPicture, _ opacity: Double, _ context: CGContext) {
        guard let image = image(of: picture) else { return }
        let rect = CGRect(picture.rect)
        context.saveGState()
        context.setAlpha(CGFloat(opacity))
        context.interpolationQuality = .high
        // A Core Graphics image is drawn with its bottom up, which a y down context shows upside down.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private static func image(of picture: OverlayPicture) -> CGImage? {
        if let made = picture.native.value { return (made as! CGImage) }
        let source = picture.image
        guard source.width > 0, source.height > 0, source.rgba.count >= source.width * source.height * 4,
              let provider = CGDataProvider(data: Data(source.rgba) as CFData),
              let image = CGImage(width: source.width, height: source.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: source.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        picture.native.value = image
        return image
    }

    private static func draw(_ label: OverlayText, _ opacity: Double, _ paint: Paint, _ context: CGContext) {
        let look = label.look
        let size = label.sizeOnScreen ? look.size / paint.scale : look.size
        if size <= 0 || label.text.isEmpty { return }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(look, size),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): paint.color(look.color, opacity),
        ]
        let lines = label.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes))
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        var widths: [Double] = []
        for line in lines {
            widths.append(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        }
        let step = ascent + descent + leading
        let width = widths.max() ?? 0
        let height = step * CGFloat(lines.count)
        let origin = label.anchor == .center ? CGPoint(x: label.at.x - width / 2, y: label.at.y - height / 2) : CGPoint(x: label.at.x, y: label.at.y)
        if let background = label.background {
            let pad = CGFloat(size * 0.2)
            context.setFillColor(paint.color(background, opacity))
            context.fill(CGRect(x: origin.x - pad, y: origin.y - pad / 2, width: width + pad * 2, height: height + pad))
        }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, line) in lines.enumerated() {
            let free = width - widths[i]
            let shift: Double
            switch look.alignment {
            case .center: shift = free / 2
            case .trailing: shift = free
            default: shift = 0
            }
            context.textPosition = CGPoint(x: origin.x + shift, y: origin.y + ascent + step * CGFloat(i))
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    static func font(_ look: OverlayTextLook, _ size: Double) -> CTFont {
        let base: String
        switch look.family {
        case "Helvetica": base = look.bold ? (look.italic ? "Helvetica-BoldOblique" : "Helvetica-Bold") : (look.italic ? "Helvetica-Oblique" : "Helvetica")
        case "Times": base = look.bold ? (look.italic ? "Times-BoldItalic" : "Times-Bold") : (look.italic ? "Times-Italic" : "Times-Roman")
        case "Courier": base = look.bold ? (look.italic ? "Courier-BoldOblique" : "Courier-Bold") : (look.italic ? "Courier-Oblique" : "Courier")
        default:
            let plain = CTFontCreateWithName(look.family as CFString, CGFloat(size), nil)
            var traits = CTFontSymbolicTraits()
            if look.bold { traits.insert(.traitBold) }
            if look.italic { traits.insert(.traitItalic) }
            return traits.isEmpty ? plain : CTFontCreateCopyWithSymbolicTraits(plain, CGFloat(size), nil, traits, traits) ?? plain
        }
        return CTFontCreateWithName(base as CFString, CGFloat(size), nil)
    }
}
#endif
