import Foundation

// Twin of windows/LazyPDF.Core/Text/TextCollector.cs: gathers the glyphs a page shows, with the clip, invisibility,
// /ActualText and artifact rules applied.

/// A glyph on its way from the interpreter to the layout: user space data from the content, display space data for the
/// layout.
final class FlowGlyph {
    var text = ""
    var quad = TextQuad.zero
    var font: PdfFont?
    var size = 0.0
    var color = RgbColor(0, 0, 0)
    var mode = 0
    var op = -1
    var form: PdfStream?
    var element = 0, offset = 0
    var mcid: Int?
    var artifact = false, vertical = false, space = false, implied = false

    /// Where the baseline sits in the box, from its bottom edge, as a fraction of its height.
    var base = 0.2

    var display = TextQuad.zero
    var em = 0.0, angle = 0.0
    var x0 = 0.0, x1 = 0.0, y = 0.0, ya = 0.0, yb = 0.0
    var level = 0
    var run = 0
}

final class TextCollector: ContentVisitor {
    private static let maxGlyphs = 1_000_000
    private static let maxCellScan = 64

    private let options: TextPageOptions
    private var spans: [(marked: MarkedContent, start: Int, text: String)] = []
    private var hiddenScopes = Set<ObjectIdentifier>()
    private var layers: LayerVisibility?

    var glyphs: [FlowGlyph] = []

    /// The page had more glyphs than are kept.
    private(set) var isFull = false

    init(_ options: TextPageOptions) {
        self.options = options
        super.init()
    }

    override func showGlyph(_ context: ContentContext, _ info: GlyphInfo) {
        let state = context.state
        if state.renderMode == 7 || !hiddenScopes.isEmpty { return }
        if glyphs.count >= Self.maxGlyphs {
            isFull = true
            return
        }
        let m = info.matrix
        var size = (m.c * m.c + m.d * m.d).squareRoot()
        let font = info.font
        var ascent: Double, descent: Double
        if font.isType3 {
            // The glyphs of a Type 3 font have the size its /FontMatrix and /FontBBox give, not the font size.
            ascent = font.ascent > 0 ? font.ascent / 1000 : 0.8
            descent = font.descent < 0 ? font.descent / 1000 : -0.2
            size *= max(ascent - descent, 1e-3)
        } else {
            ascent = font.ascent > 0 ? min(font.ascent / 1000, 1.1) : 0.8
            descent = font.descent < 0 ? max(font.descent / 1000, -0.4) : -0.2
        }
        if !(size > 1e-6) || !size.isFinite || !m.e.isFinite || !m.f.isFinite { return }

        ascent = max(ascent, font.isType3 ? 1e-3 : 0.5)
        let width = max(info.character.width / 1000, 0)
        let (x0, y0) = m.transform(0, descent)
        let (x1, y1) = m.transform(width, descent)
        let (x2, y2) = m.transform(width, ascent)
        let (x3, y3) = m.transform(0, ascent)
        let quad = TextQuad(x0, y0, x1, y1, x2, y2, x3, y3)
        if !(quad.x0 + quad.y0 + quad.x1 + quad.y1 + quad.x2 + quad.y2 + quad.x3 + quad.y3).isFinite { return }

        let box = quad.bounds
        let clip = state.clip
        if box.right < clip.left || box.left > clip.right || box.top < clip.bottom || box.bottom > clip.top { return }

        var artifact = false
        var mcid: Int?
        if !context.marked.isEmpty {
            artifact = context.marked.contains { $0.tag == "Artifact" }
            mcid = context.mcid
        }
        if artifact && !options.includeArtifacts { return }

        var text = info.unicode ?? (info.character.isSpace ? " " : "")
        text = TextNormal.clean(text)
        let g = FlowGlyph()
        g.text = text
        g.quad = quad
        g.font = font
        g.size = size
        g.color = (state.renderMode == 1 ? state.strokeColor : state.fillColor).rgb
        g.mode = state.renderMode
        g.op = context.operatorIndex
        g.form = context.forms.last
        g.element = info.element
        g.offset = info.offset
        g.mcid = mcid
        g.artifact = artifact
        g.vertical = font.isVertical
        g.space = Self.isBlank(text)
        g.base = -descent / (ascent - descent)
        glyphs.append(g)
    }

    // Content in a group that is off is not on the page, so it is not its text.
    private func hidden(_ context: ContentContext, _ group: PdfDictionary) -> Bool {
        if layers == nil { layers = LayerVisibility(context.document) }
        return layers?.isHidden(group) ?? false
    }

    override func beginForm(_ context: ContentContext, _ form: FormInfo) {
        if !form.isPattern, let group = form.optionalContent, hidden(context, group) { hiddenScopes.insert(ObjectIdentifier(form.stream)) }
    }

    override func endForm(_ context: ContentContext, _ form: FormInfo) {
        hiddenScopes.remove(ObjectIdentifier(form.stream))
    }

    override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
        if let group = marked.optionalContent, hidden(context, group) { hiddenScopes.insert(ObjectIdentifier(marked)) }
        guard spans.isEmpty, let properties = marked.properties else { return }
        if let s = context.document.resolve(properties["ActualText"]) as? PdfString {
            spans.append((marked, glyphs.count, TextNormal.clean(PdfText.decode(s.bytes))))
        }
    }

    override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
        hiddenScopes.remove(ObjectIdentifier(marked))
        guard let first = spans.first, first.marked === marked else { return }
        spans.removeAll()
        replace(first.start, first.text)
    }

    static func isBlank(_ text: String) -> Bool {
        let units = text.utf16
        return !units.isEmpty && units.allSatisfy { $0.isWhiteSpace }
    }

    // ISO 32000-1 14.9.4: the text replaces the glyphs. One piece per line the glyphs run over, the text on the first,
    // so that a hit on it still covers everything it stands for.
    private func replace(_ start: Int, _ text: String) {
        let count = glyphs.count - start
        if count <= 0 { return }
        let replaced = Array(glyphs[start...])
        glyphs.removeSubrange(start...)
        if text.isEmpty { return }
        var group = [replaced[0]]
        var first = true
        for i in 1...replaced.count {
            if i < replaced.count, let last = group.last, Self.sameLine(last, replaced[i]) {
                group.append(replaced[i])
                continue
            }
            glyphs.append(Self.merge(group, first ? text : ""))
            first = false
            group = i < replaced.count ? [replaced[i]] : []
        }
    }

    private static func sameLine(_ a: FlowGlyph, _ b: FlowGlyph) -> Bool {
        let (ca, cb) = (a.quad.center, b.quad.center)
        let rx = a.vertical ? a.quad.x0 - a.quad.x3 : a.quad.x1 - a.quad.x0
        let ry = a.vertical ? a.quad.y0 - a.quad.y3 : a.quad.y1 - a.quad.y0
        let length = (rx * rx + ry * ry).squareRoot()
        if length < 1e-9 { return true }
        let across = abs((cb.x - ca.x) * ry - (cb.y - ca.y) * rx) / length
        return across < 0.5 * a.size
    }

    private static func merge(_ group: [FlowGlyph], _ text: String) -> FlowGlyph {
        var box = QuadBox()
        for g in group { box.add(g.quad) }
        let f = group[0]
        let merged = FlowGlyph()
        merged.text = text
        merged.quad = box.toQuad()
        merged.font = f.font
        merged.size = f.size
        merged.color = f.color
        merged.mode = f.mode
        merged.op = f.op
        merged.form = f.form
        merged.element = f.element
        merged.offset = f.offset
        merged.mcid = f.mcid
        merged.artifact = f.artifact
        merged.vertical = f.vertical
        merged.space = isBlank(text)
        merged.base = f.base
        return merged
    }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    /// Drops a glyph drawn again at nearly the same place (fake bold, drop shadows).
    func removeDuplicates() {
        let cell = 4.0
        var grid: [Cell: [FlowGlyph]] = [:]
        var kept: [FlowGlyph] = []
        kept.reserveCapacity(glyphs.count)
        for g in glyphs {
            if g.text.isEmpty || g.space {
                kept.append(g)
                continue
            }
            // A C# (long) cast of a double saturates.
            let cx = Int(saturating: (g.quad.x0 / cell).rounded(.down)), cy = Int(saturating: (g.quad.y0 / cell).rounded(.down))
            // Adjacent narrow letters of the same kind (ll) sit closer than 0.2 em, so the reach is also held under a
            // quarter of the glyph's own advance.
            let advance = ((g.quad.x1 - g.quad.x0) * (g.quad.x1 - g.quad.x0) + (g.quad.y1 - g.quad.y0) * (g.quad.y1 - g.quad.y0)).squareRoot()
            let reach = advance > 1e-9 ? min(0.2 * g.size, 0.25 * advance) : 0.2 * g.size
            var duplicate = false
            // At the ends of the Int range the C# neighbour loops do not run (the sum wraps), so no neighbour is found.
            if cx > Int.min && cx < Int.max && cy > Int.min && cy < Int.max {
                scan: for i in (cx - 1)...(cx + 1) {
                    for j in (cy - 1)...(cy + 1) {
                        guard let list = grid[Cell(x: i, y: j)] else { continue }
                        var k = list.count - 1
                        while k >= max(0, list.count - Self.maxCellScan) {
                            let o = list[k]
                            if o.text.utf16.elementsEqual(g.text.utf16) && abs(o.size - g.size) < 0.1 * g.size
                                && abs(o.quad.x0 - g.quad.x0) < reach && abs(o.quad.y0 - g.quad.y0) < reach {
                                duplicate = true
                                break scan
                            }
                            k -= 1
                        }
                    }
                }
            }
            if duplicate { continue }
            kept.append(g)
            grid[Cell(x: cx, y: cy), default: []].append(g)
        }
        glyphs = kept
    }
}

enum TextNormal {
    private static func dropped(_ v: UInt32) -> Bool {
        v < 0x20 || (v >= 0x7F && v < 0xA0) || v == 0x200B || v == 0xFEFF
    }

    /// Removes control characters and folds ligature and presentation form code points to the letters they stand for.
    static func clean(_ text: String) -> String {
        var fold = false, drop = false
        for c in text.unicodeScalars {
            if dropped(c.value) {
                drop = true
            } else if (c.value >= 0xFB00 && c.value <= 0xFDFF) || (c.value >= 0xFE70 && c.value <= 0xFEFF) {
                fold = true
            }
        }
        if !drop && !fold { return text }
        var result = text
        if drop {
            var scalars = String.UnicodeScalarView()
            for c in text.unicodeScalars where !dropped(c.value) { scalars.append(c) }
            result = String(scalars)
        }
        if !fold { return result }
        return result.precomposedStringWithCompatibilityMapping
    }
}
