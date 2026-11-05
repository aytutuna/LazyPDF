import Foundation

// Twin of windows/LazyPDF.Core/Annotations/AppearanceBuilder.Shapes.cs: squares, circles, lines, polygons, ink and the
// border of a link.

extension AppearanceBuilder {
    /// Opacity, colours, width and dash of the shape; says whether it strokes and whether it fills.
    static func setup(_ c: AppearanceCanvas, _ a: PdfAnnotation, fillable: Bool) -> (stroke: Bool, fill: Bool) {
        c.transparency(a.opacity, multiply: false)
        let stroke = a.border.width > 0 && c.color(a.color ?? red, stroke: true)
        let fill = fillable && paints(a.interiorColor) && c.color(a.interiorColor, stroke: false)
        if stroke {
            c.stroke(a.border.width, a.border.style == .dashed ? a.border.dash : nil)
            c.w.raw("1 j")
        }
        return (stroke, fill)
    }

    static func paint(_ c: AppearanceCanvas, stroke: Bool, fill: Bool) {
        if stroke && fill {
            c.w.fillAndStroke()
        } else if fill {
            c.w.fill()
        } else if stroke {
            c.w.stroke()
        } else {
            c.w.endPath()
        }
    }

    func shape(_ a: PdfAnnotation, ellipse: Bool) -> AppearanceCanvas {
        let c = canvas(a)
        let (stroke, fill) = Self.setup(c, a, fillable: true)
        let rd = a.rectDifference
        let cloud = a.cloud > 0
        let half = cloud ? 0 : a.border.width / 2
        let left = a.rect.left + (rd.count == 4 ? rd[0] : 0) + half, bottom = a.rect.bottom + (rd.count == 4 ? rd[1] : 0) + half
        let right = a.rect.right - (rd.count == 4 ? rd[2] : 0) - half, top = a.rect.top - (rd.count == 4 ? rd[3] : 0) - half
        if right <= left || top <= bottom { return c }
        if cloud {
            let spacing = CloudBorder.spacing(a.cloud)
            CloudBorder.draw(c, ellipse
                ? CloudBorder.ellipsePoints(left, bottom, right, top, spacing)
                : CloudBorder.rectPoints(left, bottom, right, top, spacing))
        } else if ellipse {
            c.ellipse(left, bottom, right, top)
        } else {
            c.w.rect(c.x(left), c.y(bottom), right - left, top - bottom)
        }
        Self.paint(c, stroke: stroke, fill: fill)
        return c
    }

    func polygon(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        let (stroke, fill) = Self.setup(c, a, fillable: true)
        let points = Self.points(a.vertices)
        if points.count < 2 { return c }
        if a.cloud > 0 && points.count >= 3 {
            CloudBorder.draw(c, CloudBorder.resample(points, CloudBorder.spacing(a.cloud)))
        } else {
            c.polyline(points, close: true)
        }
        Self.paint(c, stroke: stroke, fill: fill)
        return c
    }

    func polyLine(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        let (stroke, _) = Self.setup(c, a, fillable: false)
        let points = Self.points(a.vertices)
        if points.count < 2 { return c }
        if stroke {
            c.polyline(points, close: false)
            c.w.stroke()
        }
        let first = points[0]
        let second = points[1]
        let last = points[points.count - 1]
        let before = points[points.count - 2]
        Self.drawEnding(c, a, a.startEnding, first, Self.unit(first.x - second.x, first.y - second.y))
        Self.drawEnding(c, a, a.endEnding, last, Self.unit(last.x - before.x, last.y - before.y))
        return c
    }

    func line(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        let (stroke, _) = Self.setup(c, a, fillable: false)
        if a.line.count < 4 { return c }
        let p: PdfPoint = (a.line[0], a.line[1])
        let q: PdfPoint = (a.line[2], a.line[3])
        if stroke {
            c.move(p.x, p.y).line(q.x, q.y)
            c.w.stroke()
        }
        Self.drawEnding(c, a, a.startEnding, p, Self.unit(p.x - q.x, p.y - q.y))
        Self.drawEnding(c, a, a.endEnding, q, Self.unit(q.x - p.x, q.y - p.y))
        return c
    }

    func ink(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        let (stroke, _) = Self.setup(c, a, fillable: false)
        if !stroke { return c }
        c.w.raw("1 J")
        for path in a.inkList {
            let points = Self.points(path)
            if points.isEmpty { continue }
            Self.smooth(c, points)
            c.w.stroke()
        }
        return c
    }

    // Quadratic curves between the midpoints of the samples, so a hand-drawn stroke has no corners.
    private static func smooth(_ c: AppearanceCanvas, _ p: [PdfPoint]) {
        c.move(p[0].x, p[0].y)
        if p.count == 1 {
            c.line(p[0].x, p[0].y)
            return
        }
        if p.count == 2 {
            c.line(p[1].x, p[1].y)
            return
        }
        var from = p[0]
        for i in 1..<(p.count - 1) {
            let mid: PdfPoint = ((p[i].x + p[i + 1].x) / 2, (p[i].y + p[i + 1].y) / 2)
            c.curve(from.x + 2.0 / 3 * (p[i].x - from.x), from.y + 2.0 / 3 * (p[i].y - from.y),
                    mid.x + 2.0 / 3 * (p[i].x - mid.x), mid.y + 2.0 / 3 * (p[i].y - mid.y), mid.x, mid.y)
            from = mid
        }
        c.line(p[p.count - 1].x, p[p.count - 1].y)
    }

    static func points(_ numbers: [Double]) -> [PdfPoint] {
        var points: [PdfPoint] = []
        points.reserveCapacity(numbers.count / 2)
        var i = 0
        while i + 1 < numbers.count {
            points.append((numbers[i], numbers[i + 1]))
            i += 2
        }
        return points
    }

    func link(_ a: PdfAnnotation) -> AppearanceCanvas {
        let c = canvas(a)
        if a.border.width <= 0 || !Self.paints(a.color) { return c }
        c.color(a.color, stroke: true)
        c.stroke(a.border.width, a.border.style == .dashed ? a.border.dash : nil)
        let half = a.border.width / 2
        c.w.rect(half, half, a.rect.width - a.border.width, a.rect.height - a.border.width)
        c.w.stroke()
        return c
    }
}
