import Foundation

// Twin of windows/LazyPDF.Core/Office/Pptx/PptxShapes.cs: shapes, pictures, groups, connectors and tables of a slide, layout or master.

extension PptxReader {
    struct FillInfo {
        let color: Int?
        let gradient: Bool
    }

    /// An a:xfrm in points: where the box is, and for a group the box its children are placed in.
    struct Xfrm {
        let x: Double, y: Double, width: Double, height: Double
        let childX: Double, childY: Double, childWidth: Double, childHeight: Double
        let rotation: Double
        let flipH: Bool, flipV: Bool
    }

    /// A box turned back upright: the corner, size, and the turn clockwise in degrees (after mirroring left to right).
    struct Upright {
        let x: Double, y: Double, width: Double, height: Double
        let rotation: Double
        let flipH: Bool

        var turned: Bool { rotation > 0.01 && rotation < 359.99 }
    }

    final class LineInfo {
        var width: Double?
        var color: Int?
        var none = false
        var dash = "solid"
        var headType = "none", headWidth = "med", headLength = "med"
        var tailType = "none", tailWidth = "med", tailLength = "med"
    }

    func staticShapes(_ template: Template, _ scope: Scope) throws -> [PptxShape] {
        try makeShapes(template.root, scope, place: false)
    }

    // The shapes of a slide, layout or master that can be drawn. On a layout or master the placeholders are only templates.
    private func makeShapes(_ root: OfficeXmlElement, _ scope: Scope, place: Bool) throws -> [PptxShape] {
        var list: [PptxShape] = []
        var seen = 0
        try walk(Self.children(Self.tree(root)), scope, place, .identity, 0, &list, &seen)
        return list
    }

    func slideShapes(_ root: OfficeXmlElement, _ scope: Scope) throws -> [PptxShape] {
        try makeShapes(root, scope, place: true)
    }

    private func walk(_ elements: [OfficeXmlElement], _ scope: Scope, _ place: Bool, _ context: Affine, _ depth: Int, _ list: inout [PptxShape], _ seen: inout Int) throws {
        for e in elements {
            if e.uri != Self.p || e.name == "nvGrpSpPr" || e.name == "grpSpPr" || e.name == "extLst" { continue }
            if e.name == "sp" && !place && Self.placeholderOf(e) != nil { continue }
            seen += 1
            if seen > limits.maxShapes {
                skip(PptxSkipped.shape)
                continue
            }
            try Task.checkCancellation()
            switch e.name {
            case "sp", "cxnSp":
                if let shape = try makeShape(e, scope, context) { list.append(shape) }
            case "pic":
                if let picture = try pic(e, scope, context) { list.append(picture) }
            case "grpSp":
                try group(e, scope, place, context, depth, &list, &seen)
            case "graphicFrame":
                if let frame = try graphicFrame(e, scope, context) { list.append(frame) }
            default:
                skip(PptxSkipped.shape)
            }
        }
    }

    private func group(_ group: OfficeXmlElement, _ scope: Scope, _ place: Bool, _ context: Affine, _ depth: Int, _ list: inout [PptxShape], _ seen: inout Int) throws {
        guard depth < limits.maxGroupDepth, let x = Self.readXfrm(group.child(Self.p, "grpSpPr")?.child(DocxReader.a, "xfrm")) else {
            skip(PptxSkipped.shape)
            return
        }
        let scale = Affine.scale(x.childWidth > 0 ? x.width / x.childWidth : 1, x.childHeight > 0 ? x.height / x.childHeight : 1)
        let inner = context.multiply(Self.placement(x)).multiply(scale).multiply(.translate(-x.childX, -x.childY))
        try walk(Self.children(group), scope, place, inner, depth + 1, &list, &seen)
    }

    // ---- positions ----

    static func readXfrm(_ xfrm: OfficeXmlElement?) -> Xfrm? {
        let a = DocxReader.a
        let offset = xfrm?.child(a, "off")
        let extent = xfrm?.child(a, "ext")
        guard let xfrm, let x = DocxReader.number(offset?.attribute("x")), let y = DocxReader.number(offset?.attribute("y")),
              let cx = DocxReader.number(extent?.attribute("cx")), let cy = DocxReader.number(extent?.attribute("cy")) else {
            return nil
        }
        let far = 1e9
        func emu(_ v: Double, _ low: Double) -> Double { PptxColors.clamp(v, low, far) / emuPerPoint }
        let width = emu(cx, 0), height = emu(cy, 0), left = emu(x, -far), top = emu(y, -far)
        let childOffset = xfrm.child(a, "chOff")
        let childExtent = xfrm.child(a, "chExt")
        let hasChildren = childOffset != nil && childExtent != nil
        return Xfrm(x: left, y: top, width: width, height: height,
                    childX: hasChildren ? emu(DocxReader.number(childOffset!.attribute("x")) ?? 0, -far) : left,
                    childY: hasChildren ? emu(DocxReader.number(childOffset!.attribute("y")) ?? 0, -far) : top,
                    childWidth: hasChildren ? emu(DocxReader.number(childExtent!.attribute("cx")) ?? 0, 0) : width,
                    childHeight: hasChildren ? emu(DocxReader.number(childExtent!.attribute("cy")) ?? 0, 0) : height,
                    rotation: (DocxReader.number(xfrm.attribute("rot")) ?? 0) / 60000,
                    flipH: PptxRunProps.flag(xfrm.attribute("flipH")) == true,
                    flipV: PptxRunProps.flag(xfrm.attribute("flipV")) == true)
    }

    // Takes the box 0, 0 to width, height to where the xfrm puts it: mirrored, then turned about its center.
    static func placement(_ x: Xfrm) -> Affine {
        if x.rotation == 0 && !x.flipH && !x.flipV { return .translate(x.x, x.y) }
        return Affine.translate(x.x + x.width / 2, x.y + x.height / 2)
            .multiply(.rotate(x.rotation))
            .multiply(.scale(x.flipH ? -1 : 1, x.flipV ? -1 : 1))
            .multiply(.translate(-x.width / 2, -x.height / 2))
    }

    // What a box of width x height placed by the transform looks like turned back upright.
    static func uncover(_ m: Affine, _ w: Double, _ h: Double) -> Upright {
        let width = Affine.length(m.a, m.b) * w, height = Affine.length(m.c, m.d) * h
        let det = m.a * m.d - m.b * m.c
        var angle = atan2(m.b, m.a) * 180 / Double.pi - (det < 0 ? 180 : 0)
        angle = angle.truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        if m.b == 0 && m.c == 0 {
            return Upright(x: m.a >= 0 ? m.e : m.e + m.a * w, y: m.d >= 0 ? m.f : m.f + m.d * h, width: width, height: height, rotation: angle, flipH: det < 0)
        }
        let center = m.apply(w / 2, h / 2)
        return Upright(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height, rotation: angle, flipH: det < 0)
    }

    static func place(_ m: Affine, _ c: PathCommand) -> PathCommand {
        switch c {
        case .move(let x, let y):
            let q = m.apply(x, y)
            return .move(q.x, q.y)
        case .line(let x, let y):
            let q = m.apply(x, y)
            return .line(q.x, q.y)
        case .curve(let x1, let y1, let x2, let y2, let x, let y):
            let a = m.apply(x1, y1), b = m.apply(x2, y2), q = m.apply(x, y)
            return .curve(a.x, a.y, b.x, b.y, q.x, q.y)
        case .close:
            return c
        }
    }

    // ---- fills and lines ----

    func fillOf(_ spPr: OfficeXmlElement?, _ colors: PptxColors) -> FillInfo? {
        for e in spPr?.elements ?? [] where e.uri == DocxReader.a {
            switch e.name {
            case "noFill": return FillInfo(color: nil, gradient: false)
            case "solidFill": return FillInfo(color: colors.first(e), gradient: false)
            case "gradFill": return FillInfo(color: colors.first(e.child(DocxReader.a, "gsLst")?.child(DocxReader.a, "gs")), gradient: true)
            case "blipFill", "pattFill", "grpFill": return FillInfo(color: nil, gradient: false)
            default: break
            }
        }
        return nil
    }

    static func applyLine(_ info: LineInfo, _ ln: OfficeXmlElement?, _ colors: PptxColors, _ placeholder: Int?) {
        guard let ln else { return }
        let a = DocxReader.a
        if let width = DocxReader.number(ln.attribute("w")) { info.width = PptxColors.clamp(width / emuPerPoint, 0, 1584) }
        for e in ln.elements where e.uri == a {
            switch e.name {
            case "noFill":
                info.none = true
                info.color = nil
            case "solidFill":
                info.none = false
                info.color = colors.first(e, placeholder)
            case "gradFill":
                info.none = false
                info.color = colors.first(e.child(a, "gsLst")?.child(a, "gs"), placeholder)
            case "prstDash": info.dash = e.attribute("val") ?? "solid"
            case "custDash": info.dash = "dash"
            case "headEnd": (info.headType, info.headWidth, info.headLength) = (e.attribute("type") ?? "none", e.attribute("w") ?? "med", e.attribute("len") ?? "med")
            case "tailEnd": (info.tailType, info.tailWidth, info.tailLength) = (e.attribute("type") ?? "none", e.attribute("w") ?? "med", e.attribute("len") ?? "med")
            default: break
            }
        }
    }

    // The outline of a shape: the theme line the style points at, then the master's, the layout's and the shape's own line over it.
    static func lineOf(_ spPr: OfficeXmlElement?, _ layoutPr: OfficeXmlElement?, _ masterPr: OfficeXmlElement?, _ style: OfficeXmlElement?, _ scope: Scope) -> LineInfo? {
        let a = DocxReader.a
        let info = LineInfo()
        if let reference = style?.child(a, "lnRef"), let idx = DocxReader.number(reference.attribute("idx")), idx > 0 {
            let color = scope.colors.first(reference)
            let list = scope.master.theme?.child(a, "themeElements")?.child(a, "fmtScheme")?.child(a, "lnStyleLst")?.elements ?? []
            let at = Int(min(idx, 1000)) - 1
            info.color = color
            info.width = 0.75
            applyLine(info, at >= 0 && at < list.count ? list[at] : nil, scope.colors, color)
        }
        for layer in [masterPr, layoutPr, spPr] { applyLine(info, layer?.child(a, "ln"), scope.colors, nil) }
        return info.none || info.color == nil ? nil : info
    }

    private static func dash(_ name: String, _ width: Double) -> [Double] {
        let pattern: [Double]
        switch name {
        case "dot": pattern = [1, 3]
        case "sysDot": pattern = [1, 1]
        case "dash", "custDash": pattern = [4, 3]
        case "sysDash": pattern = [3, 1]
        case "lgDash": pattern = [8, 3]
        case "dashDot": pattern = [4, 3, 1, 3]
        case "sysDashDot": pattern = [3, 1, 1, 1]
        case "lgDashDot": pattern = [8, 3, 1, 3]
        case "lgDashDotDot": pattern = [8, 3, 1, 3, 1, 3]
        case "sysDashDotDot": pattern = [3, 1, 1, 1, 1, 1]
        default: pattern = []
        }
        let unit = max(width, 0.25)
        return pattern.map { $0 * unit }
    }

    static func stroke(_ line: LineInfo) -> PathStroke {
        let width = max(line.width ?? 0.75, 0.25)
        return PathStroke(width: width, color: line.color!, dash: dash(line.dash, width))
    }

    private static func adjust(_ geometry: OfficeXmlElement?) -> [String: Double] {
        var values: [String: Double] = [:]
        for gd in (geometry?.child(DocxReader.a, "avLst")?.elements(DocxReader.a, "gd") ?? []).prefix(8) {
            if let name = gd.attribute("name"), let formula = gd.attribute("fmla"), formula.hasPrefix("val "),
               let v = DocxReader.number(String(formula.dropFirst(4))) {
                values[name] = v
            }
        }
        return values
    }

    // ---- sp and cxnSp ----

    private func makeShape(_ sp: OfficeXmlElement, _ scope: Scope, _ context: Affine) throws -> PptxShape? {
        let p = Self.p, a = DocxReader.a
        let spPr = sp.child(p, "spPr")
        let ph = Self.placeholderOf(sp)
        var layoutPh: Placeholder?
        var masterPh: Placeholder?
        if let ph {
            let type = ph.attribute("type")
            let index = Int(PptxColors.clamp(DocxReader.number(ph.attribute("idx")) ?? 0, 0, Double(Int32.max)))
            layoutPh = scope.layout.flatMap { Self.match($0.placeholders, type, index, true) }
            masterPh = Self.match(scope.master.placeholders, layoutPh?.type ?? type, layoutPh?.index ?? index, false)
        }
        let layoutPr = layoutPh?.shape.child(p, "spPr")
        let masterPr = masterPh?.shape.child(p, "spPr")

        let geometry = spPr?.child(a, "prstGeom") ?? layoutPr?.child(a, "prstGeom") ?? masterPr?.child(a, "prstGeom")
        var preset = geometry?.attribute("prst")
        let txBox = sp.child(p, "nvSpPr")?.child(p, "cNvSpPr")?.attribute("txBox")
        let textBox = txBox == "1" || txBox == "true"
        // A geometry that is not drawn still gives its shape a place for the text.
        var outline = true
        if spPr?.child(a, "custGeom") != nil {
            skip(PptxSkipped.customGeometry)
            outline = false
            preset = "rect"
        } else if let named = preset {
            if !PptxGeometry.supports(named) {
                skip(PptxSkipped.shape)
                outline = false
                preset = "rect"
            }
        } else {
            if ph == nil && !textBox {
                skip(PptxSkipped.shape)
                return nil
            }
            preset = "rect"
        }
        let shapeName = preset!
        let isLine = PptxGeometry.isLine(shapeName)

        let style = sp.child(p, "style")
        let fill = fillOf(spPr, scope.colors) ?? fillOf(layoutPr, scope.colors) ?? fillOf(masterPr, scope.colors)
        var fillColor = fill?.color
        if fill == nil, let fillRef = style?.child(a, "fillRef"), let idx = DocxReader.number(fillRef.attribute("idx")), idx > 0 {
            fillColor = scope.colors.first(fillRef)
        }
        if !outline || isLine { fillColor = nil }
        if let fill, fill.gradient, fillColor != nil { skip(PptxSkipped.gradient) }
        let line = outline ? Self.lineOf(spPr, layoutPr, masterPr, style, scope) : nil

        let body = try sp.child(p, "txBody").flatMap { try makeBody($0, ph, layoutPh, masterPh, scope, style) }
        if fillColor == nil && body == nil && line == nil { return nil }

        guard let x = Self.readXfrm(spPr?.child(a, "xfrm") ?? layoutPr?.child(a, "xfrm") ?? masterPr?.child(a, "xfrm")) else {
            skip(PptxSkipped.shape)
            return nil
        }
        if spPr?.child(a, "effectLst")?.elements.isEmpty == false || spPr?.child(a, "scene3d") != nil || spPr?.child(a, "sp3d") != nil {
            skip(PptxSkipped.effect)
        }

        let matrix = context.multiply(Self.placement(x))
        let frame = Self.uncover(matrix, x.width, x.height)
        if body != nil && frame.turned { skip(PptxSkipped.textRotation) }

        // A rectangle with a plain fill, upright, is drawn as the box itself; anything else as an outline.
        let plain = shapeName == "rect" && line == nil && matrix.b == 0 && matrix.c == 0 && matrix.a > 0 && matrix.d > 0
        var paths: [PlacedPath] = []
        if !plain && (fillColor != nil || line != nil) {
            var commands = PptxGeometry.build(shapeName, x.width, x.height, Self.adjust(geometry)).map { Self.place(matrix, $0) }
            let stroke = line.map { Self.stroke($0) }
            if isLine, let stroke { Self.arrowheads(&commands, line!, stroke, &paths) }
            paths.insert(PlacedPath(commands: commands, fill: fillColor, stroke: stroke), at: 0)
        }

        return PptxShape(x: frame.x, y: frame.y, width: frame.width, height: frame.height, fill: plain ? fillColor : nil, paths: paths, body: body)
    }

    // The heads at the two ends of a line, which also shorten the line so that its stroke does not poke through them.
    private static func arrowheads(_ line: inout [PathCommand], _ info: LineInfo, _ stroke: PathStroke, _ paths: inout [PlacedPath]) {
        guard case .move(let x0, let y0) = line[0], case .line(let x1, let y1) = line[1] else { return }
        let length = Affine.length(x1 - x0, y1 - y0)
        if length < 0.01 { return }
        let dx = (x1 - x0) / length, dy = (y1 - y0) / length
        let back0 = head(info.headType, info.headWidth, info.headLength, x0, y0, -dx, -dy, stroke, &paths)
        let back1 = head(info.tailType, info.tailWidth, info.tailLength, x1, y1, dx, dy, stroke, &paths)
        line[0] = .move(x0 + dx * back0, y0 + dy * back0)
        line[1] = .line(x1 - dx * back1, y1 - dy * back1)
    }

    // One head with its tip at (x, y) pointing along (dx, dy); returns how far the line has to stop short of the tip.
    private static func head(_ type: String, _ widthName: String, _ lengthName: String, _ x: Double, _ y: Double, _ dx: Double, _ dy: Double,
                             _ stroke: PathStroke, _ paths: inout [PlacedPath]) -> Double {
        if !["triangle", "stealth", "diamond", "oval", "arrow"].contains(type) { return 0 }
        let unit = max(stroke.width, 2)
        func size(_ name: String) -> Double { (name == "sm" ? 2 : name == "lg" ? 5 : 3) * unit }
        let width = size(widthName), length = size(lengthName)
        // u is the distance back from the tip along the line, v the distance to the side.
        func at(_ u: Double, _ v: Double) -> (Double, Double) { (x - dx * u - dy * v, y - dy * u + dx * v) }
        func move(_ p: (Double, Double)) -> PathCommand { .move(p.0, p.1) }
        func line(_ p: (Double, Double)) -> PathCommand { .line(p.0, p.1) }
        switch type {
        case "triangle":
            paths.append(PlacedPath(commands: [move(at(0, 0)), line(at(length, -width / 2)), line(at(length, width / 2)), .close], fill: stroke.color, stroke: nil))
            return length
        case "stealth":
            paths.append(PlacedPath(commands: [move(at(0, 0)), line(at(length, -width / 2)), line(at(length * 0.65, 0)), line(at(length, width / 2)), .close], fill: stroke.color, stroke: nil))
            return length * 0.5
        case "diamond":
            paths.append(PlacedPath(commands: [move(at(0, 0)), line(at(length / 2, -width / 2)), line(at(length, 0)), line(at(length / 2, width / 2)), .close], fill: stroke.color, stroke: nil))
            return length / 2
        case "oval":
            let kappa = 0.5522847498307936
            let ka = length / 2 * kappa, kb = width / 2 * kappa, mid = length / 2, side = width / 2
            func curve(_ a: (Double, Double), _ b: (Double, Double), _ to: (Double, Double)) -> PathCommand { .curve(a.0, a.1, b.0, b.1, to.0, to.1) }
            paths.append(PlacedPath(commands: [
                move(at(0, 0)),
                curve(at(0, kb), at(mid - ka, side), at(mid, side)),
                curve(at(mid + ka, side), at(length, kb), at(length, 0)),
                curve(at(length, -kb), at(mid + ka, -side), at(mid, -side)),
                curve(at(mid - ka, -side), at(0, -kb), at(0, 0)),
                .close,
            ], fill: stroke.color, stroke: nil))
            return length / 2
        default:
            paths.append(PlacedPath(commands: [move(at(length, -width / 2)), line(at(0, 0)), line(at(length, width / 2))], fill: nil,
                                    stroke: PathStroke(width: stroke.width, color: stroke.color, dash: [])))
            return 0
        }
    }
}
