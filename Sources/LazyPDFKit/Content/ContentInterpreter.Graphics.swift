import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentInterpreter.Graphics.cs: line state, ExtGState, paths and colour.

extension ContentInterpreter {
    func resetPath() {
        path.removeAll()
        pendingClip = 0
    }

    func setDash(_ op: ContentOperation) {
        let count = op.operands.count
        guard count >= 2, let array = op.operands[count - 2] as? PdfArray, let phase = op.operands[count - 1] as? PdfNumber else { return }
        state.dash = dashArray(array)
        state.dashPhase = phase.value
    }

    private func dashArray(_ array: PdfArray) -> [Double] {
        array.items.prefix(64).map { item in
            if let number = document.resolve(item) as? PdfNumber, number.value.isFinite { return number.value }
            return 0
        }
    }

    func setExtGState(_ op: ContentOperation) {
        guard let name = nameOperand(op), let g = findResource("ExtGState", name) as? PdfDictionary else { return }
        if let lw = document.number(g, "LW") { state.lineWidth = lw }
        if let lc = document.integer(g, "LC") { state.lineCap = Int(Int32(truncatingIfNeeded: lc)) }
        if let lj = document.integer(g, "LJ") { state.lineJoin = Int(Int32(truncatingIfNeeded: lj)) }
        if let ml = document.number(g, "ML") { state.miterLimit = ml }
        if let d = document.array(g, "D"), d.items.count >= 2, let dash = document.resolve(d.items[0]) as? PdfArray,
           let phase = document.resolve(d.items[1]) as? PdfNumber {
            state.dash = dashArray(dash)
            state.dashPhase = phase.value
        }
        if let f = document.array(g, "Font"), f.items.count >= 2, let font = document.resolve(f.items[0]) as? PdfDictionary,
           let size = document.resolve(f.items[1]) as? PdfNumber {
            state.font = self.font(font)
            state.fontSize = size.value
        }
        if let stroke = document.number(g, "CA") { state.strokeAlpha = Swift.min(Swift.max(stroke, 0), 1) }
        if let fill = document.number(g, "ca") { state.fillAlpha = Swift.min(Swift.max(fill, 0), 1) }
        var blend = document.resolve(g["BM"])
        if let modes = blend as? PdfArray, !modes.items.isEmpty { blend = document.resolve(modes.items[0]) }
        if let mode = blend as? PdfName { state.blendMode = mode.value }
        if g.containsKey("SMask") { state.softMask = document.resolve(g["SMask"]) as? PdfDictionary }
    }

    func buildPath(_ op: ContentOperation) {
        let ctm = state.ctm
        switch op.operator {
        case "m":
            guard let p = numbers(op, 2) else { return }
            let t = ctm.transform(p[0], p[1])
            (curX, curY) = t
            (startX, startY) = t
            add(.move, curX, curY)
        case "l":
            guard let p = numbers(op, 2) else { return }
            (curX, curY) = ctm.transform(p[0], p[1])
            if path.isEmpty {
                (startX, startY) = (curX, curY)
                add(.move, curX, curY)
            } else {
                add(.line, curX, curY)
            }
        case "c":
            guard let p = numbers(op, 6), !path.isEmpty else { return }
            curve(ctm.transform(p[0], p[1]), ctm.transform(p[2], p[3]), ctm.transform(p[4], p[5]))
        case "v":
            guard let p = numbers(op, 4), !path.isEmpty else { return }
            curve((curX, curY), ctm.transform(p[0], p[1]), ctm.transform(p[2], p[3]))
        case "y":
            guard let p = numbers(op, 4), !path.isEmpty else { return }
            let end = ctm.transform(p[2], p[3])
            curve(ctm.transform(p[0], p[1]), end, end)
        case "h":
            if path.isEmpty { return }
            add(.close, 0, 0)
            (curX, curY) = (startX, startY)
        case "re":
            guard let p = numbers(op, 4) else { return }
            let a = ctm.transform(p[0], p[1])
            let b = ctm.transform(p[0] + p[2], p[1])
            let c = ctm.transform(p[0] + p[2], p[1] + p[3])
            let d = ctm.transform(p[0], p[1] + p[3])
            add(.move, a.x, a.y)
            add(.line, b.x, b.y)
            add(.line, c.x, c.y)
            add(.line, d.x, d.y)
            add(.close, 0, 0)
            (curX, curY) = a
            (startX, startY) = a
        default: break
        }
    }

    private func add(_ kind: PathSegmentKind, _ x: Double, _ y: Double) {
        if path.count < Self.maxSegments { path.append(PathSegment(kind, x, y, 0, 0, 0, 0)) }
    }

    private func curve(_ c1: (x: Double, y: Double), _ c2: (x: Double, y: Double), _ end: (x: Double, y: Double)) {
        if path.count < Self.maxSegments { path.append(PathSegment(.curve, c1.x, c1.y, c2.x, c2.y, end.x, end.y)) }
        (curX, curY) = end
    }

    func paintPath(_ op: String) {
        let close = op == "s" || op == "b" || op == "b*"
        let fill = op == "f" || op == "F" || op == "f*" || op == "B" || op == "B*" || op == "b" || op == "b*"
        let stroke = op == "S" || op == "s" || op == "B" || op == "B*" || op == "b" || op == "b*"
        if !path.isEmpty {
            if close { add(.close, 0, 0) }
            let bounds = pathBounds()
            if fill || stroke || pendingClip != 0 {
                let grow = stroke ? Swift.max(state.lineWidth, 0) * state.ctm.scaleFactor / 2 : 0
                let ink = PdfRect(bounds.left - grow, bounds.bottom - grow, bounds.right + grow, bounds.top + grow)
                visitor.paintPath(context, PathInfo(op, path, bounds, ink, fill, stroke, op == "f*" || op == "B*" || op == "b*", pendingClip != 0))
                if fill { walkPattern(state.fillColor) }
                if stroke { walkPattern(state.strokeColor) }
            }
            if pendingClip != 0 { state.clip = state.clip.intersect(bounds) }
        }
        resetPath()
    }

    private func pathBounds() -> PdfRect {
        var x1 = Double.greatestFiniteMagnitude, y1 = Double.greatestFiniteMagnitude
        var x2 = -Double.greatestFiniteMagnitude, y2 = -Double.greatestFiniteMagnitude
        func include(_ x: Double, _ y: Double) {
            x1 = nanMin(x1, x)
            y1 = nanMin(y1, y)
            x2 = nanMax(x2, x)
            y2 = nanMax(y2, y)
        }
        for s in path {
            if s.kind == .close { continue }
            include(s.x1, s.y1)
            if s.kind != .curve { continue }
            include(s.x2, s.y2)
            include(s.x3, s.y3)
        }
        return x1 > x2 ? PdfRect(0, 0, 0, 0) : PdfRect(x1, y1, x2, y2)
    }

    func setDeviceColor(_ op: ContentOperation) {
        let first = op.operator.unicodeScalars.first ?? " "
        let space: ColorSpaceInfo
        switch first {
        case "g", "G": space = ColorSpaceInfo.deviceGray
        case "r", "R": space = ColorSpaceInfo.deviceRgb
        default: space = ColorSpaceInfo.deviceCmyk
        }
        guard let values = numbers(op, space.components) else { return }
        let color = PdfColor(space, values)
        if first.properties.isUppercase {
            state.strokeColor = color
        } else {
            state.fillColor = color
        }
    }

    func setColorSpace(_ op: ContentOperation) {
        guard let name = nameOperand(op) else { return }
        let space = resolveSpace(name)
        let color = PdfColor(space, space.initialColor())
        if op.operator == "CS" {
            state.strokeColor = color
        } else {
            state.fillColor = color
        }
    }

    private func resolveSpace(_ name: String) -> ColorSpaceInfo {
        switch name {
        case "DeviceGray", "G": return ColorSpaceInfo.deviceGray
        case "DeviceRGB", "RGB": return ColorSpaceInfo.deviceRgb
        case "DeviceCMYK", "CMYK": return ColorSpaceInfo.deviceCmyk
        default: break
        }
        let definition: PdfObject? = name == "Pattern" ? PdfName(name) : findResource("ColorSpace", name)
        guard let definition else { return ColorSpaceInfo.deviceGray }
        let key: SpaceKey = (definition as? PdfName).map { .name($0.value) } ?? .object(ObjectIdentifier(definition))
        if let known = colorSpaces[key] { return known.space }
        let space = ColorSpaceInfo.create(document, definition)
        if colorSpaces.count < 256 { colorSpaces[key] = (definition, space) }
        return space
    }

    func setColor(_ op: ContentOperation) {
        let stroke = op.operator.unicodeScalars.first == "S"
        let space = stroke ? state.strokeColor.space : state.fillColor.space
        let values = op.operands.compactMap { $0 as? PdfNumber }.prefix(32).map { $0.value }
        let color: PdfColor
        if space.family == "Pattern" {
            let patternName = op.operands.last as? PdfName
            let pattern = patternName.flatMap { findResource("Pattern", $0.value) }
            color = PdfColor(space, values, patternName, pattern)
        } else if !values.isEmpty {
            color = PdfColor(space, values)
        } else {
            return
        }
        if stroke {
            state.strokeColor = color
        } else {
            state.fillColor = color
        }
    }
}
