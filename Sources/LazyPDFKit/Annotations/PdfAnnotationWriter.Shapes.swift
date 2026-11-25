import Foundation

// Twin of windows/LazyPDF.Core/Annotations/PdfAnnotationWriter.Shapes.cs: text markup, rectangles, ovals, lines,
// polygons and ink.

extension PdfAnnotationWriter {
    /// A Highlight, Underline, StrikeOut or Squiggly over the quads the caller found for the text. The default colour is
    /// yellow for a highlight and red for the rest.
    @discardableResult
    public func addTextMarkup(_ page: PdfPage, _ kind: AnnotationType, _ quads: [MarkupQuad], info: AnnotationInfo? = nil, style: AnnotationStyle? = nil) throws -> PdfAnnotation {
        guard kind == .highlight || kind == .underline || kind == .strikeOut || kind == .squiggly else { throw ArgumentException("Not a text markup kind.") }
        guard !quads.isEmpty else { throw ArgumentException("A text markup needs at least one quad.") }
        let style = style ?? AnnotationStyle()
        let d = newAnnotation(kind.rawValue, Self.inflate(Self.union(quads), 1), info,
                              style.color ?? (kind == .highlight ? AppearanceBuilder.yellow : AppearanceBuilder.red), style.opacity)
        d["QuadPoints"] = Self.numbers(quads.flatMap { $0.toNumbers() })
        return try place(page, d)
    }

    @discardableResult
    public func addSquare(_ page: PdfPage, _ rect: PdfRect, style: AnnotationStyle? = nil, info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        try addBox(page, "Square", rect, style, info)
    }

    @discardableResult
    public func addCircle(_ page: PdfPage, _ rect: PdfRect, style: AnnotationStyle? = nil, info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        try addBox(page, "Circle", rect, style, info)
    }

    private func addBox(_ page: PdfPage, _ subtype: String, _ rect: PdfRect, _ style: AnnotationStyle?, _ info: AnnotationInfo?) throws -> PdfAnnotation {
        let style = style ?? AnnotationStyle()
        let d = newAnnotation(subtype, rect, info, style.color ?? AppearanceBuilder.red, style.opacity)
        Self.decorate(d, style)
        if style.cloud > 0 {
            let inset = CloudBorder.bulge(style.cloud) + style.width / 2
            d["RD"] = Self.numbers([inset, inset, inset, inset])
        }
        return try place(page, d)
    }

    private static func decorate(_ d: PdfDictionary, _ style: AnnotationStyle) {
        setBorder(d, style)
        if let fill = style.fill { d["IC"] = numbers(fill) }
        if style.cloud > 0 {
            let be = PdfDictionary()
            be["S"] = PdfName("C")
            be["I"] = PdfNumber(min(max(style.cloud, 1), 2))
            d["BE"] = be
        }
    }

    @discardableResult
    public func addLine(_ page: PdfPage, _ from: PdfPoint, _ to: PdfPoint, style: AnnotationStyle? = nil, info: AnnotationInfo? = nil,
                        start: LineEnding = .none, end: LineEnding = .none) throws -> PdfAnnotation {
        let style = style ?? AnnotationStyle()
        let margin = Self.margin(style, start != .none || end != .none)
        let d = newAnnotation("Line", Self.inflate(Self.boundsOf([from, to]), margin), info, style.color ?? AppearanceBuilder.red, style.opacity)
        d["L"] = Self.numbers([from.x, from.y, to.x, to.y])
        d["LE"] = Self.endings(start, end)
        Self.decorate(d, style)
        return try place(page, d)
    }

    /// A line with an open arrow head at `to`, marked /IT /LineArrow as Acrobat's arrow tool does.
    @discardableResult
    public func addArrow(_ page: PdfPage, _ from: PdfPoint, _ to: PdfPoint, style: AnnotationStyle? = nil, info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        let style = style ?? AnnotationStyle()
        let margin = Self.margin(style, true)
        let d = newAnnotation("Line", Self.inflate(Self.boundsOf([from, to]), margin), info, style.color ?? AppearanceBuilder.red, style.opacity)
        d["L"] = Self.numbers([from.x, from.y, to.x, to.y])
        d["LE"] = Self.endings(.none, .openArrow)
        d["IT"] = PdfName("LineArrow")
        Self.decorate(d, style)
        return try place(page, d)
    }

    @discardableResult
    public func addPolyLine(_ page: PdfPage, _ points: [PdfPoint], style: AnnotationStyle? = nil, info: AnnotationInfo? = nil,
                            start: LineEnding = .none, end: LineEnding = .none) throws -> PdfAnnotation {
        guard points.count >= 2 else { throw ArgumentException("A polyline needs two points.") }
        let style = style ?? AnnotationStyle()
        let margin = Self.margin(style, start != .none || end != .none)
        let d = newAnnotation("PolyLine", Self.inflate(Self.boundsOf(points), margin), info, style.color ?? AppearanceBuilder.red, style.opacity)
        d["Vertices"] = Self.numbers(points.flatMap { [$0.x, $0.y] })
        d["LE"] = Self.endings(start, end)
        Self.decorate(d, style)
        return try place(page, d)
    }

    @discardableResult
    public func addPolygon(_ page: PdfPage, _ points: [PdfPoint], style: AnnotationStyle? = nil, info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        try addClosed(page, points, style ?? AnnotationStyle(), info, intent: nil)
    }

    /// A polygon with a cloud border (/IT /PolygonCloud); the style's cloud intensity is 1 when it has none.
    @discardableResult
    public func addCloud(_ page: PdfPage, _ points: [PdfPoint], style: AnnotationStyle? = nil, info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        var style = style ?? AnnotationStyle()
        if style.cloud <= 0 { style.cloud = 1 }
        return try addClosed(page, points, style, info, intent: "PolygonCloud")
    }

    private func addClosed(_ page: PdfPage, _ points: [PdfPoint], _ style: AnnotationStyle, _ info: AnnotationInfo?, intent: String?) throws -> PdfAnnotation {
        guard points.count >= 3 else { throw ArgumentException("A polygon needs three points.") }
        let margin = style.width + (style.cloud > 0 ? CloudBorder.bulge(style.cloud) : 0)
        let d = newAnnotation("Polygon", Self.inflate(Self.boundsOf(points), margin), info, style.color ?? AppearanceBuilder.red, style.opacity)
        d["Vertices"] = Self.numbers(points.flatMap { [$0.x, $0.y] })
        if let intent { d["IT"] = PdfName(intent) }
        Self.decorate(d, style)
        return try place(page, d)
    }

    /// Freehand strokes, each a list of sampled points; they are drawn smoothed.
    @discardableResult
    public func addInk(_ page: PdfPage, _ strokes: [[PdfPoint]], style: AnnotationStyle? = nil, info: AnnotationInfo? = nil) throws -> PdfAnnotation {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { throw ArgumentException("There are no points.") }
        let style = style ?? AnnotationStyle()
        let d = newAnnotation("Ink", Self.inflate(Self.boundsOf(all), style.width / 2 + 1), info, style.color ?? AppearanceBuilder.red, style.opacity)
        d["InkList"] = PdfArray(strokes.filter { !$0.isEmpty }.map { Self.numbers($0.flatMap { [$0.x, $0.y] }) })
        Self.setBorder(d, style)
        return try place(page, d)
    }

    /// The /Rect a drawn mark needs at `width`, from its points with the same room it was given when made; nil for any other kind.
    public static func markBox(_ a: PdfAnnotation, width: Double, head: Bool) -> PdfRect? {
        func points(_ values: [Double]) -> [PdfPoint] {
            stride(from: 0, to: values.count - 1, by: 2).map { (values[$0], values[$0 + 1]) }
        }
        let style = AnnotationStyle(width: width)
        switch a.type {
        case .line, .polyLine:
            let p = points(a.type == .line ? a.line : a.vertices)
            return p.isEmpty ? nil : inflate(boundsOf(p), margin(style, head))
        case .polygon:
            let p = points(a.vertices)
            return p.isEmpty ? nil : inflate(boundsOf(p), width + (a.cloud > 0 ? CloudBorder.bulge(a.cloud) : 0))
        case .ink:
            let p = a.inkList.flatMap(points)
            return p.isEmpty ? nil : inflate(boundsOf(p), width / 2 + 1)
        default:
            return nil
        }
    }

    private static func margin(_ style: AnnotationStyle, _ endings: Bool) -> Double {
        endings ? AppearanceBuilder.endingSize(style.width) + style.width : style.width / 2 + 1
    }

    private static func endings(_ start: LineEnding, _ end: LineEnding) -> PdfArray {
        PdfArray([PdfName(start.rawValue), PdfName(end.rawValue)])
    }
}
