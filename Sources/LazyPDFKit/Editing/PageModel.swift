import Foundation

// Twin of windows/LazyPDF.Core/Editing/PageModel.cs: a page read for editing: its text as `TextPage` lays it out, its
// glyphs, images and paths with the streams and operations they came from, and the selectable objects built from them.

final class PageModel {
    private struct OpKey: Hashable {
        let unit: ContentUnit
        let op: Int
    }

    private struct CharKey: Hashable {
        let form: ObjectIdentifier?
        let op: Int
        let element: Int
        let offset: Int
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private init(_ document: PdfDocument, _ page: PdfPage, _ scan: EditScan, _ text: TextPage) {
        self.document = document
        self.page = page
        self.scan = scan
        self.text = text
        charGlyphs = [EditGlyph?](repeating: nil, count: text.chars.count)
    }

    let document: PdfDocument
    let page: PdfPage
    let scan: EditScan
    let text: TextPage

    /// The glyph behind each character of `TextPage.chars`; nil for an implied space or a character the content does not show as such.
    var charGlyphs: [EditGlyph?]

    var objects: [PageObject] = []

    private var byOp: [OpKey: [EditGlyph]]?

    /// The glyphs one operation shows.
    func glyphsAt(_ unit: ContentUnit, _ op: Int) -> [EditGlyph] {
        let known: [OpKey: [EditGlyph]]
        if let byOp {
            known = byOp
        } else {
            var built: [OpKey: [EditGlyph]] = [:]
            for g in scan.glyphs { built[OpKey(unit: g.unit, op: g.op), default: []].append(g) }
            byOp = built
            known = built
        }
        return known[OpKey(unit: unit, op: op)] ?? []
    }

    /// A glyph that is not in `own` is shown between `a` and `b`, in their strings or the ones between.
    func foreignBetween(_ unit: ContentUnit, _ a: EditGlyph, _ b: EditGlyph, _ own: Set<EditGlyph>) -> Bool {
        var op = a.op
        while op <= b.op {
            for g in glyphsAt(unit, op) {
                if own.contains(g) { continue }
                let afterA = op > a.op || (g.element, g.offset) > (a.element, a.offset)
                let beforeB = op < b.op || (g.element, g.offset) < (b.element, b.offset)
                if afterA && beforeB { return true }
            }
            op += 1
        }
        return false
    }

    private var lineAlignment: [Int: TextAlignment] = [:]

    func alignmentOfLine(_ line: Int) -> TextAlignment? { lineAlignment[line] }

    static func load(_ document: PdfDocument, _ pageIndex: Int) -> PageModel {
        let page = document.pages[pageIndex]
        let scan = EditScan(document, page)
        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        interpreter.run(page, scan)
        let text = TextPage.create(document, page)
        text.requirePageContent()
        let model = PageModel(document, page, scan, text)
        model.mapChars()
        model.buildObjects()
        return model
    }

    private func mapChars() {
        var byKey: [CharKey: [EditGlyph]] = [:]
        for g in scan.glyphs {
            byKey[CharKey(form: g.unit.form.map { ObjectIdentifier($0) }, op: g.op, element: g.element, offset: g.offset), default: []].append(g)
        }
        var claimed = Set<EditGlyph>()
        var claimedInOrder: [EditGlyph] = []
        for c in text.chars {
            if c.operatorIndex < 0 { continue }
            guard let list = byKey[CharKey(form: c.form.map { ObjectIdentifier($0) }, op: c.operatorIndex, element: c.element, offset: c.offset)] else { continue }
            let center = c.quad.center
            var nearest: EditGlyph?
            var distance = Double.greatestFiniteMagnitude
            for g in list {
                let gc = g.quad.center
                let d = abs(gc.x - center.x) + abs(gc.y - center.y)
                if d < distance && !claimed.contains(g) {
                    distance = d
                    nearest = g
                }
            }
            guard let best = nearest else { continue }
            claimed.insert(best)
            claimedInOrder.append(best)
            charGlyphs[c.index] = best
        }
        attachTwins(claimed, claimedInOrder)
    }

    private static func cellOf(_ value: Double, _ cell: Double) -> Int {
        let floor = (value / cell).rounded(.down)
        // Keeps the neighbours cx - 1 and cx + 1 inside Int whatever the file put in the matrix.
        return floor.isNaN ? 0 : Int(Swift.min(Swift.max(floor, -4e18), 4e18))
    }

    // A glyph drawn again at nearly the same place is dropped from the text; it is cut with the one it copies.
    private func attachTwins(_ claimed: Set<EditGlyph>, _ claimedInOrder: [EditGlyph]) {
        if claimed.count == scan.glyphs.count { return }
        let cell = 4.0
        var grid: [Cell: [EditGlyph]] = [:]
        for g in claimedInOrder {
            grid[Cell(x: Self.cellOf(g.matrix.e, cell), y: Self.cellOf(g.matrix.f, cell)), default: []].append(g)
        }
        glyphs: for g in scan.glyphs {
            if claimed.contains(g) || g.text.isEmpty || g.hasActualText { continue }
            let cx = Self.cellOf(g.matrix.e, cell), cy = Self.cellOf(g.matrix.f, cell)
            for i in (cx - 1)...(cx + 1) {
                for j in (cy - 1)...(cy + 1) {
                    guard let list = grid[Cell(x: i, y: j)] else { continue }
                    for other in list {
                        if other.text.utf16.elementsEqual(g.text.utf16) && abs(other.matrix.e - g.matrix.e) < 0.2 * other.userSize
                            && abs(other.matrix.f - g.matrix.f) < 0.2 * other.userSize {
                            other.twins.append(g)
                            continue glyphs
                        }
                    }
                }
            }
        }
    }

    private func buildObjects() {
        var found: [(sequence: Int, make: (Int) -> PageObject)] = []
        for block in text.blocks {
            let glyphs = blockGlyphs(block)
            if glyphs.isEmpty { continue }
            found.append((glyphs.map { $0.sequence }.max() ?? 0, { id in self.makeText(id, block, glyphs) }))
        }
        for image in scan.images {
            found.append((image.sequence, { id in
                ImageObject(id, Self.shown(image), image.unit, image.visit, image.sequence, image.info, image.opacity, image.op)
            }))
        }
        for path in scan.paths {
            found.append((path.sequence, { id in
                PathObject(id, path.info.inkBounds, path.unit, path.visit, path.sequence, path.info, path.style, path.firstOp, path.paintOp)
            }))
        }
        let ordered = found.enumerated().sorted { a, b in
            a.element.sequence != b.element.sequence ? a.element.sequence < b.element.sequence : a.offset < b.offset
        }
        for (_, item) in ordered { objects.append(item.make(objects.count)) }
    }

    func blockChars(_ block: TextBlock) -> TextRange {
        if block.lines.isEmpty { return TextRange(0, 0) }
        return TextRange(text.lines[block.lines.start].range.start, text.lines[block.lines.end - 1].range.end)
    }

    func blockGlyphs(_ block: TextBlock) -> [EditGlyph] { glyphsIn(blockChars(block)) }

    func glyphsIn(_ range: TextRange) -> [EditGlyph] {
        var list: [EditGlyph] = []
        var i = Swift.max(range.start, 0)
        let end = Swift.min(range.end, charGlyphs.count)
        while i < end {
            if let g = charGlyphs[i] { list.append(g) }
            i += 1
        }
        return list
    }

    // The part of a picture a clip leaves showing, which is what a person sees and grabs.
    private static func shown(_ image: ImageRecord) -> PdfRect {
        let visible = image.info.bounds.intersect(image.clip)
        return visible.isEmpty ? image.info.bounds : visible
    }

    private func makeText(_ id: Int, _ block: TextBlock, _ glyphs: [EditGlyph]) -> TextObject {
        let first = glyphs.first { !($0.text.utf16.first ?? 0x20).isWhiteSpace } ?? glyphs[0]
        var lines: [TextObjectLine] = []
        var i = block.lines.start
        while i < block.lines.end {
            let line = text.lines[i]
            lines.append(TextObjectLine(index: line.index, range: line.range, text: line.text, bounds: line.bounds))
            i += 1
        }
        let chars = blockChars(block)
        let (alignment, spacing) = BlockLayout.detect(text, block, scan.glyphs.isEmpty ? nil : first, self)
        i = block.lines.start
        while i < block.lines.end {
            lineAlignment[i] = alignment
            i += 1
        }
        let object = TextObject(id, block.bounds, first.unit, first.visit, glyphs.map { $0.sequence }.max() ?? 0, block)
        object.glyphs = glyphs
        object.lines = lines
        object.text = text.getText(chars)
        object.range = chars
        object.font = first.font
        object.size = first.userSize
        object.color = first.color
        object.charSpacing = first.charSpacing
        object.alignment = alignment
        object.lineSpacing = spacing
        return object
    }
}

/// Alignment and line spacing of a block, read from where its lines start and end.
enum BlockLayout {
    static func detect(_ text: TextPage, _ block: TextBlock, _ anchor: EditGlyph?, _ model: PageModel) -> (alignment: TextAlignment, spacing: Double) {
        guard let anchor, block.lines.count > 0 else { return (.left, 0) }
        let (ux, uy) = anchor.direction
        let size = Swift.max(anchor.userSize, 1)
        var starts: [Double] = []
        var ends: [Double] = []
        var origins: [(x: Double, y: Double)] = []
        var i = block.lines.start
        while i < block.lines.end {
            let q = text.lines[i].quad
            starts.append(q.x0 * ux + q.y0 * uy)
            ends.append(q.x1 * ux + q.y1 * uy)
            if let glyph = model.glyphsIn(text.lines[i].range).first { origins.append(glyph.origin) }
            i += 1
        }
        let spacing = origins.count > 1 ? abs((origins[1].x - origins[0].x) * -uy + (origins[1].y - origins[0].y) * ux) : 0
        if starts.count < 2 { return (.left, spacing) }
        let tol = 0.6 * size
        func same(_ values: [Double], _ within: Double) -> Bool {
            guard let high = values.max(), let low = values.min() else { return false }
            return high - low <= within
        }
        let centers = zip(starts, ends).map { ($0 + $1) / 2 }
        if same(starts, tol) {
            // The last line of a justified paragraph is short.
            if starts.count >= 3 && same(Array(ends.dropLast()), 0.15 * size) { return (.justify, spacing) }
            return (.left, spacing)
        }
        if same(ends, tol) { return (.right, spacing) }
        if same(centers, tol) { return (.center, spacing) }
        return (.left, spacing)
    }
}
