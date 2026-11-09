import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/Marker.cs: adds, changes and finds marks on the open document. Page points are in
// the display space the viewer uses. Finding a mark under a point is in Marker+Find.swift.

public enum MarkTool: CaseIterable {
    case selectText, edit, note, textBox, callout, line, arrow, rectangle, oval, polygon, cloud, pencil, eraser, stamp, attach
}

/// How a new mark looks. A nil colour takes the default of its kind.
public struct MarkStyle: Equatable {
    public var color: [Double]?
    public var width: Double
    public var opacity: Double
    public var family: String
    public var size: Double
    public var font: FontStyles

    public init(color: [Double]? = nil, width: Double = 2, opacity: Double = 1, family: String = "Helvetica", size: Double = 12,
                font: FontStyles = .regular) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.family = family
        self.size = size
        self.font = font
    }

    public static let `default` = MarkStyle()

    func toAnnotation() -> AnnotationStyle {
        AnnotationStyle(color: color, width: width, opacity: opacity)
    }

    func toText() -> FreeTextStyle {
        FreeTextStyle(family: family, size: size, font: font, textColor: color ?? [0, 0, 0])
    }
}

public final class Marker {
    public static let noteSize = 20.0
    public static let calloutWidth = 150.0
    public static let calloutHeight = 50.0
    public static let stampWidth = 130.0
    public static let stampHeight = 44.0

    let document: PdfDocument
    private let writer: PdfAnnotationWriter
    private let author: String
    private let date: DateTimeOffset

    public init(_ document: PdfDocument, _ fonts: FontSource?, author: String, date: DateTimeOffset) {
        self.document = document
        self.author = author
        self.date = date
        writer = PdfAnnotationWriter(document, fonts)
    }

    private func info(_ text: String = "") -> AnnotationInfo {
        AnnotationInfo(author: author, contents: text, subject: nil, date: date)
    }

    // On a turned page text and stamps are told to stay upright (NoRotate), their natural size hung from the corner shown top left.
    private func upright(_ geometry: PageGeometry, _ text: String = "") -> AnnotationInfo {
        var made = info(text)
        if geometry.rotation != 0 { made.flags = [.print, .noRotate] }
        return made
    }

    func standing(_ geometry: PageGeometry, _ box: ViewRect) -> PdfRect {
        geometry.rotation == 90 || geometry.rotation == 270
            ? geometry.toUser(DisplayRect(box.x, box.y, box.height, box.width))
            : geometry.toUser(DisplayRect(box.x, box.y, box.width, box.height))
    }

    func stands(_ a: PdfAnnotation, _ geometry: PageGeometry) -> Bool {
        a.flags.contains(.noRotate) && geometry.rotation != 0
    }

    private func faded(_ made: PdfAnnotation, _ style: MarkStyle) throws -> PdfAnnotation {
        style.opacity < 1 ? try writer.setOpacity(made, style.opacity) : made
    }

    public static func quad(_ q: TextQuad) -> MarkupQuad {
        MarkupQuad(q.x3, q.y3, q.x2, q.y2, q.x0, q.y0, q.x1, q.y1)
    }

    public func markup(_ kind: AnnotationType, _ runs: [SelectedRun], _ style: MarkStyle) throws -> Int {
        var count = 0
        for run in runs where !run.quads.isEmpty && run.page < document.pages.count {
            _ = try writer.addTextMarkup(document.pages[run.page], kind, run.quads.map(Self.quad), info: info(), style: style.toAnnotation())
            count += 1
        }
        return count
    }

    /// The box a text box or callout takes from the points the person gave, in display space.
    public static func box(for tool: MarkTool, _ points: [ViewPoint]) -> ViewRect {
        let last = points[points.count - 1]
        if tool == .callout { return ViewRect(last.x - calloutWidth / 2, last.y - calloutHeight / 2, calloutWidth, calloutHeight) }
        return ViewRect(from: points[0], to: last)
    }

    @discardableResult
    public func add(_ tool: MarkTool, _ page: Int, _ points: [ViewPoint], _ style: MarkStyle, _ text: String = "") throws -> PdfAnnotation {
        let target = document.pages[page]
        let geometry = PageGeometry(target)
        func user(_ p: ViewPoint) -> PdfPoint { geometry.toUser(p.x, p.y) }
        func userRect(_ r: ViewRect) -> PdfRect { geometry.toUser(DisplayRect(r.x, r.y, r.width, r.height)) }
        let last = points[points.count - 1]
        var shape = style.toAnnotation()
        let standingInfo = upright(geometry, text)
        switch tool {
        case .note:
            let box = ViewRect(points[0].x, points[0].y, Self.noteSize, Self.noteSize)
            return try faded(writer.addNote(target, userRect(box), info(text), icon: "Note", color: style.color), style)
        case .textBox:
            shape.width = 0
            return try writer.addFreeText(target, standing(geometry, Self.box(for: tool, points)), text, font: style.toText(), style: shape, info: standingInfo)
        case .callout:
            let box = Self.box(for: tool, points)
            let anchor = points[0]
            let middle = box.y + box.height / 2, across = box.x + box.width / 2
            let edges = [ViewPoint(box.left, middle), ViewPoint(box.right, middle), ViewPoint(across, box.top), ViewPoint(across, box.bottom)]
            let edge = edges.min { Self.squared($0, anchor) < Self.squared($1, anchor) } ?? edges[0]
            var framed = shape
            framed.width = max(1, style.width)
            if geometry.rotation == 0 {
                return try writer.addFreeText(target, userRect(box), text, font: style.toText(), style: framed, info: standingInfo,
                                              callout: [user(anchor), user(edge)])
            }
            // A callout line is drawn in user space and would turn the text with the page, so a turned page gets a box and an arrow.
            let boxed = try writer.addFreeText(target, standing(geometry, box), text, font: style.toText(), style: framed, info: standingInfo)
            _ = try writer.addArrow(target, user(edge), user(anchor), style: shape, info: info())
            return boxed
        case .line:
            return try writer.addLine(target, user(points[0]), user(last), style: shape, info: info())
        case .arrow:
            return try writer.addArrow(target, user(points[0]), user(last), style: shape, info: info())
        case .rectangle:
            return try writer.addSquare(target, userRect(ViewRect(from: points[0], to: last)), style: shape, info: info())
        case .oval:
            return try writer.addCircle(target, userRect(ViewRect(from: points[0], to: last)), style: shape, info: info())
        case .polygon:
            return try writer.addPolygon(target, points.map(user), style: shape, info: info())
        case .cloud:
            shape.cloud = 2
            return try writer.addCloud(target, points.map(user), style: shape, info: info())
        case .pencil:
            return try writer.addInk(target, [points.map(user)], style: shape, info: info())
        default:
            throw ArgumentException("This tool does not draw by itself.")
        }
    }

    private static func squared(_ a: ViewPoint, _ b: ViewPoint) -> Double {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    public func addStamp(_ page: Int, _ center: ViewPoint, _ name: String, _ style: MarkStyle) throws -> PdfAnnotation {
        let target = document.pages[page]
        let geometry = PageGeometry(target)
        let box = standing(geometry, ViewRect(center.x - Self.stampWidth / 2, center.y - Self.stampHeight / 2, Self.stampWidth, Self.stampHeight))
        return try faded(writer.addStamp(target, box, name, info: upright(geometry), color: style.color), style)
    }

    public func addAttachment(_ page: Int, _ at: ViewPoint, _ fileName: String, _ data: [UInt8]) throws -> PdfAnnotation {
        let target = document.pages[page]
        let box = PageGeometry(target).toUser(DisplayRect(at.x, at.y, Self.noteSize, Self.noteSize))
        return try writer.addFileAttachment(target, box, fileName, data, info: info(), icon: "PushPin")
    }

    public func find(_ page: Int, _ number: Int) -> PdfAnnotation? {
        page < 0 || page >= document.pages.count ? nil
            : PdfAnnotations.read(document, document.pages[page]).first { $0.reference?.number == number }
    }

    /// False when the annotation's page is no longer in the file.
    public func onPage(_ a: PdfAnnotation) -> Bool {
        a.pageIndex >= 0 && a.pageIndex < document.pages.count
    }

    /// The annotation's box in display space.
    public func box(of a: PdfAnnotation) -> ViewRect {
        let page = document.pages[a.pageIndex]
        let geometry = PageGeometry(page)
        let box = geometry.toDisplay(a.rect)
        if stands(a, geometry) { return ViewRect(box.x, box.y, a.rect.width * page.userUnit, a.rect.height * page.userUnit) }
        return ViewRect(box.x, box.y, box.width, box.height)
    }

    public func move(_ a: PdfAnnotation, _ dx: Double, _ dy: Double) throws -> PdfAnnotation {
        let geometry = PageGeometry(document.pages[a.pageIndex])
        let (x0, y0) = geometry.toUser(0, 0)
        let (x1, y1) = geometry.toUser(dx, dy)
        return try writer.move(a, x1 - x0, y1 - y0)
    }

    public func resize(_ a: PdfAnnotation, _ box: ViewRect) throws -> PdfAnnotation {
        let geometry = PageGeometry(document.pages[a.pageIndex])
        let rect = stands(a, geometry) ? standing(geometry, box) : geometry.toUser(DisplayRect(box.x, box.y, box.width, box.height))
        let resized = try writer.resize(a, rect)
        // The writer scales the rectangle and the callout line but not the insets that place the box in it.
        if a.rectDifference.count != 4 || a.rect.width <= 0 || a.rect.height <= 0 { return resized }
        let sx = rect.width / a.rect.width, sy = rect.height / a.rect.height
        let scale = [sx, sy, sx, sy]
        resized.dictionary["RD"] = PdfArray(a.rectDifference.enumerated().map { PdfNumber($0.element * scale[$0.offset]) })
        try writer.regenerate(resized)
        return find(a.pageIndex, a.reference?.number ?? -1) ?? resized
    }

    /// Paints the mark; a text box takes the colour for its frame and its text.
    public func recolor(_ a: PdfAnnotation, _ color: [Double]) throws -> PdfAnnotation {
        if a.type != .freeText { return try setColor(a, color) }
        let painted = try writer.setColor(a, color)
        var text = Self.textOf(painted)
        text.textColor = color
        text.richText = nil
        return try writer.setFreeTextStyle(painted, text)
    }

    private func setColor(_ a: PdfAnnotation, _ color: [Double]) throws -> PdfAnnotation {
        let filled = [AnnotationType.square, .circle, .polygon].contains(a.type) && !(a.interiorColor ?? []).isEmpty
        return filled ? try writer.setColor(a, color, interior: color) : try writer.setColor(a, color)
    }

    public func setOpacity(_ a: PdfAnnotation, _ opacity: Double) throws -> PdfAnnotation {
        try writer.setOpacity(a, opacity)
    }

    public func setWidth(_ a: PdfAnnotation, _ width: Double) throws -> PdfAnnotation {
        let border = (document.dict(a.dictionary, "BS") ?? PdfDictionary()).copy()
        border["W"] = PdfNumber(width)
        a.dictionary["BS"] = border
        try writer.regenerate(a)
        return find(a.pageIndex, a.reference?.number ?? -1) ?? a
    }

    public func setText(_ a: PdfAnnotation, _ text: String) throws -> PdfAnnotation {
        try writer.setContents(a, text, date: date)
    }

    /// Gives a text box the font, size and style of `style` and keeps its colour and alignment. Rich text goes, as it would
    /// hide the change.
    public func restyle(_ a: PdfAnnotation, _ style: MarkStyle) throws -> PdfAnnotation {
        var text = Self.textOf(a)
        text.family = style.family
        text.size = style.size
        text.font = style.font
        text.richText = nil
        return try writer.setFreeTextStyle(a, text)
    }

    @discardableResult
    public func delete(_ a: PdfAnnotation) -> Bool {
        writer.delete(a)
    }

    private static let face = try! NSRegularExpression(pattern: #"/(\w+)\s+([\d.]+)\s+Tf"#)
    private static let fill = try! NSRegularExpression(pattern: #"((?:-?[\d.]+\s+){1,4})(?:g|rg|k)\b"#)

    /// What a text box is set in, read from its /DA.
    public static func textOf(_ a: PdfAnnotation) -> FreeTextStyle {
        let da = a.defaultAppearance ?? ""
        let whole = NSRange(da.startIndex..., in: da)
        var family = "Helvetica"
        var size = 12.0
        var font = FontStyles.regular
        if let match = face.firstMatch(in: da, range: whole), let nameRange = Range(match.range(at: 1), in: da),
           let sizeRange = Range(match.range(at: 2), in: da) {
            let name = String(da[nameRange])
            family = name.hasPrefix("Ti") ? "Times New Roman" : name.hasPrefix("Co") ? "Courier New" : "Helvetica"
            if ["Bo", "BI", "BO"].contains(where: { name.hasSuffix($0) }) { font.insert(.bold) }
            if ["It", "Ob", "BI", "BO"].contains(where: { name.hasSuffix($0) }) { font.insert(.italic) }
            if let parsed = Double(String(da[sizeRange])) { size = parsed }
        }
        var color: [Double]?
        if let match = fill.matches(in: da, range: whole).last, let valuesRange = Range(match.range(at: 1), in: da) {
            let values = da[valuesRange].split(whereSeparator: { $0.isWhitespace }).map { Double($0) ?? .nan }
            if values.allSatisfy({ $0.isFinite }) { color = values }
        }
        return FreeTextStyle(family: family, size: size, font: font, textColor: color, alignment: a.alignment, richText: a.richText)
    }

    /// A colour of gray, RGB or CMYK as RGB; nil for anything else, and for none.
    public static func rgb(of color: [Double]?) -> [Double]? {
        guard let color else { return nil }
        switch color.count {
        case 1: return [color[0], color[0], color[0]]
        case 3: return color
        case 4: return [(1 - color[0]) * (1 - color[3]), (1 - color[1]) * (1 - color[3]), (1 - color[2]) * (1 - color[3])]
        default: return nil
        }
    }
}
