import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionScan.cs: walks a page and records what meets the marks, per content stream
// and operator index: glyphs, paths, images, shadings and the marked content that held them. What it meets under a soft mask,
// with a pattern, or in optional content it does not take out: `unhandled` says so, and the page is not redacted in place.

class ContentEdit {}

final class DeleteEdit: ContentEdit {
    static let instance = DeleteEdit()
}

/// Text around the operation, which stays in place: a clip with a hole in it for a shading.
final class SurroundEdit: ContentEdit {
    let before: String
    let after: String

    init(_ before: String, _ after: String) {
        self.before = before
        self.after = after
    }
}

struct GlyphKey: Hashable {
    let element: Int
    let offset: Int
}

/// Glyphs to cut out of the strings of one show operator, with the kerning that stands in for each.
final class TextEdit: ContentEdit {
    var removed: [GlyphKey: (length: Int, adjust: Double)] = [:]
}

final class ImageEdit: ContentEdit {
    let image: PdfStream
    let areas: [MarkArea]
    let matrix: PdfMatrix

    init(_ image: PdfStream, _ areas: [MarkArea], _ matrix: PdfMatrix) {
        self.image = image
        self.areas = areas
        self.matrix = matrix
    }
}

/// A painted or clipping path to remove, and the polygons left of it outside the marks (in page space; none for a path that goes whole).
final class PathEdit: ContentEdit {
    let clips: Bool
    let ctm: PdfMatrix
    let remains: [[MarkPoint]]

    init(_ clips: Bool, _ ctm: PdfMatrix, _ remains: [[MarkPoint]]) {
        self.clips = clips
        self.ctm = ctm
        self.remains = remains
    }
}

/// How many times each stream was met, by identity (the C# Dictionary<PdfStream, int> with ReferenceEqualityComparer).
struct StreamCounts {
    private var counts: [ObjectIdentifier: (stream: PdfStream, count: Int)] = [:]

    subscript(stream: PdfStream) -> Int {
        get { counts[ObjectIdentifier(stream)]?.count ?? 0 }
        set { counts[ObjectIdentifier(stream)] = (stream, newValue) }
    }

    func count(_ id: ObjectIdentifier) -> Int { counts[id]?.count ?? 0 }

    var identifiers: [ObjectIdentifier] { Array(counts.keys) }
}

/// One content stream in use: the page, or a form as it is painted at one place.
final class ScanNode {
    let form: PdfStream?
    var edits: [Int: ContentEdit] = [:]
    var children: [Int: ScanNode] = [:]
    var dirtyMarked: [Int: PdfDictionary] = [:]

    init(_ form: PdfStream?) {
        self.form = form
    }

    var hasEdits: Bool { !edits.isEmpty || !dirtyMarked.isEmpty || children.values.contains { $0.hasEdits } }
}

final class RedactionScan: ContentVisitor {
    private struct FontCode: Hashable {
        let font: ObjectIdentifier
        let code: Int
    }

    private let areas: [MarkArea]
    private var nodes: [ScanNode] = [ScanNode(nil)]
    private var openMarks: [(node: ScanNode, op: Int, marked: MarkedContent)] = []
    private var inks: [FontCode: PdfRect?] = [:]
    private var layers: LayerVisibility?
    private var declared: RedactionObjects.Identities?

    init(_ areas: [MarkArea]) {
        self.areas = areas
        super.init()
    }

    var root: ScanNode { nodes[0] }
    private(set) var glyphs = 0
    private(set) var images = 0
    private(set) var paths = 0

    /// Something under a mark is painted through a soft mask, a pattern or optional content.
    private(set) var unhandled = false

    /// How many times each form or picture has something cut out of it; every other use of it still names the original.
    private(set) var edited = StreamCounts()

    /// Painted items per page-level MCID, and how many of them were removed.
    private(set) var marked: [Int: (total: Int, removed: Int)] = [:]

    private var current: ScanNode { nodes[nodes.count - 1] }

    override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
        let font = glyph.font
        // The same limits TextCollector puts on a descriptor, so that the box is where the text is read from.
        let ascent: Double = font.isType3 ? (font.ascent > 0 ? font.ascent / 1000 : 0.8) : max(font.ascent > 0 ? min(font.ascent / 1000, 1.1) : 0.8, 0.5)
        let descent: Double = font.descent < 0 ? (font.isType3 ? font.descent / 1000 : max(font.descent / 1000, -0.4)) : -0.2
        let box = Geometry.corners(glyph.matrix, 0, descent, glyph.character.width / 1000, ascent)
        if !areas.contains(where: { Geometry.glyphMeets(box, $0) }) && !(font.isType3 && inkMeets(context.document, glyph)) {
            count(context, false)
            return
        }
        count(context, true)
        glyphs += 1
        // The procedure of a glyph that goes stays in the font, and a bitmap glyph is a picture that stays with it.
        if font.isType3 { unhandled = true }
        let state = context.state
        guardPaint(context, [0, 2, 4, 6].contains(state.renderMode), [1, 2, 5, 6].contains(state.renderMode), nil)
        let scale = font.isVertical ? state.fontSize : state.fontSize * state.horizontalScale
        let adjust = scale == 0 ? 0 : -glyph.advance * 1000 / scale
        let edit: TextEdit
        if let existing = current.edits[context.operatorIndex] {
            guard let text = existing as? TextEdit else {
                unhandled = true
                return
            }
            edit = text
        } else {
            edit = TextEdit()
            current.edits[context.operatorIndex] = edit
        }
        edit.removed[GlyphKey(element: glyph.element, offset: glyph.offset)] = (glyph.character.length, adjust)
    }

    // A procedure paints where it pleases (9.6.5), so a Type 3 glyph goes when what it paints meets a mark, whatever its box.
    private func inkMeets(_ document: PdfDocument, _ glyph: GlyphInfo) -> Bool {
        let key = FontCode(font: ObjectIdentifier(glyph.font.dictionary), code: glyph.code)
        let ink: PdfRect?
        if let known = inks[key] {
            ink = known
        } else {
            let found = RedactionGlyphs.procedure(document, glyph.font, glyph.code).flatMap { RedactionGlyphs.ink(document, glyph.font, $0) }
            inks[key] = found
            ink = found
        }
        guard let box = ink, !box.isEmpty else { return false }
        let drawn = Geometry.corners(glyph.matrix, box.left, box.bottom, box.right, box.top)
        return areas.contains { Geometry.overlaps(drawn, $0) }
    }

    // A soft mask (11.6.5.2) or a pattern with anything but shapes in it (8.7) paints through a shape the scan does not enter,
    // and optional content (8.11) can hide what is under a mark from the viewer while it stays in the file. Taking the shape
    // out would not take out what they hold.
    private func guardPaint(_ context: ContentContext, _ fill: Bool, _ stroke: Bool, _ optional: PdfDictionary?) {
        let state = context.state
        func risky(_ color: PdfColor) -> Bool {
            if color.pattern == nil && color.patternName == nil { return false }
            if let pattern = color.pattern, RedactionPatterns.plain(context.document, pattern) { return false }
            return true
        }
        if state.softMask != nil || (fill && risky(state.fillColor)) || (stroke && risky(state.strokeColor))
            || conditional(context.document, optional) || conditional(context.document, context.optionalContent) {
            unhandled = true
        }
    }

    // A layer that the file declares, is on and has no expression to decide shows what is there, and the shape goes like any other; the rest may hide it.
    private func conditional(_ document: PdfDocument, _ group: PdfDictionary?) -> Bool {
        guard let group else { return false }
        let hidden = layers ?? LayerVisibility(document)
        layers = hidden
        var known = declared
        if known == nil {
            var found = RedactionObjects.Identities()
            for layer in PdfLayers.read(document).layers {
                if let dictionary = document.get(layer.reference.number) as? PdfDictionary { found.insert(dictionary) }
            }
            known = found
            declared = found
        }
        let type = document.name(group, "Type")
        var members: [PdfDictionary] = [group]
        if type == "OCMD" {
            let resolved = document.resolve(group["OCGs"])
            let list: [PdfObject?] = (resolved as? PdfArray).map { $0.items.map { document.resolve($0) } } ?? [resolved]
            members = list.compactMap { $0 as? PdfDictionary }
        }
        return !(type == "OCG" || type == "OCMD") || group.containsKey("VE") || hidden.isHidden(group)
            || members.contains { !(known?.contains($0) ?? false) }
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        let paints = path.fill || path.stroke
        if !(paints || path.clips) { return }
        var path = path
        if path.stroke {
            path = PathInfo(path.operator, path.segments, path.bounds, Self.grown(path, context.state), path.fill, path.stroke, path.evenOdd, path.clips)
        }
        let hit = areas.filter { RedactionPaths.meets(path, $0) }
        if hit.isEmpty {
            if paints { count(context, false) }
            return
        }
        // A rectangle that only clips and holds every mark shows no shape; one with an edge inside a mark, or the clip of anything else, can be the marked shape itself.
        if !paints, let clip = RedactionPaths.axisRectangle(path), hit.allSatisfy({ Self.covers(clip, $0.bounds) }) { return }
        count(context, true)
        paths += 1
        let state = context.state
        if paints { guardPaint(context, path.fill, path.stroke, nil) }
        var remains: [[MarkPoint]] = []
        if state.ctm.invert() != nil {
            if path.clips {
                remains = RedactionPaths.outside(path, hit)
            } else if path.fill && !path.stroke && state.fillColor.pattern == nil && state.fillColor.patternName == nil && state.softMask == nil,
                      let rect = RedactionPaths.axisRectangle(path) {
                remains = RedactionPaths.around(rect, hit)
            }
        }
        current.edits[context.operatorIndex] = PathEdit(path.clips, state.ctm, remains)
    }

    // A stroke reaches the width of the line times the largest stretch of the matrix, further at a miter join and past a square cap (8.4.3).
    private static func grown(_ path: PathInfo, _ state: GraphicsState) -> PdfRect {
        let m = state.ctm
        let sum = m.a * m.a + m.b * m.b + m.c * m.c + m.d * m.d, determinant = m.a * m.d - m.b * m.c
        let stretch = ((sum + nanMax(sum * sum - 4 * determinant * determinant, 0).squareRoot()) / 2).squareRoot()
        let join = state.lineJoin == 0 && path.segments.count > 2 ? nanMax(state.miterLimit, 1) : 1
        let grow = nanMax(state.lineWidth, 0) * stretch / 2 * nanMax(join, 2.0.squareRoot())
        let b = path.bounds
        return PdfRect(b.left - grow, b.bottom - grow, b.right + grow, b.top + grow)
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        let square = Geometry.corners(image.matrix, 0, 0, 1, 1)
        let hit = areas.filter { Geometry.overlaps(square, $0) }
        if hit.isEmpty {
            count(context, false)
            return
        }
        count(context, true)
        images += 1
        guardPaint(context, image.isMask, false, image.optionalContent)
        guard let stream = image.stream else {
            current.edits[context.operatorIndex] = DeleteEdit.instance
            return
        }
        // The cut makes copies of the masks too, so a second holder of one still names the original.
        for held in [stream] + ImageRedactor.masks(context.document, stream) { edited[held] += 1 }
        current.edits[context.operatorIndex] = ImageEdit(stream, hit, image.matrix)
    }

    override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
        if !areas.contains(where: { Geometry.meets(shading.bounds, $0) }) { return }
        let dictionary = shading.shading as? PdfDictionary ?? (shading.shading as? PdfStream)?.dictionary
        guardPaint(context, false, false, nil)
        // Mesh and function shadings carry their samples in the file, and the clip hole hides them without removing them.
        if let dictionary, let type = context.document.integer(dictionary, "ShadingType"), type == 1 || type >= 4 {
            count(context, true)
            paths += 1
            current.edits[context.operatorIndex] = DeleteEdit.instance
            return
        }
        guard let back = context.state.ctm.invert() else { return }
        count(context, true)
        let everything = Geometry.corners(back, -1e6, -1e6, 1e6, 1e6)
        let holes = areas.map { a in a.points.map { back.transform($0.x, $0.y) } }
        var path = "q\n"
        for polygon in [everything] + holes { RedactionPaths.polygon(&path, polygon) }
        path += "W* n\n"
        current.edits[context.operatorIndex] = SurroundEdit(path, "\nQ")
    }

    override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
        openMarks.append((current, context.operatorIndex, marked))
    }

    override func endMarked(_ context: ContentContext, _ marked: MarkedContent) {
        if !openMarks.isEmpty { openMarks.removeLast() }
    }

    override func beginForm(_ context: ContentContext, _ form: FormInfo) {
        let child = ScanNode(form.stream)
        current.children[context.operatorIndex] = child
        nodes.append(child)
    }

    override func endForm(_ context: ContentContext, _ form: FormInfo) {
        // The interpreter ends every form it began; the root is never popped.
        guard nodes.count > 1 else { return }
        let child = nodes.removeLast()
        if !child.hasEdits { return }
        edited[form.stream] += 1
        if conditional(context.document, form.optionalContent) { unhandled = true }
    }

    private static func covers(_ outer: PdfRect, _ inner: PdfRect) -> Bool {
        outer.left <= inner.left && outer.bottom <= inner.bottom && outer.right >= inner.right && outer.top >= inner.top
    }

    private func count(_ context: ContentContext, _ removed: Bool) {
        if removed {
            // A description of the text in a sequence that lost some of it would give it away.
            for entry in openMarks {
                // Whatever else the properties hold, a description among it is not known to be free of the removed text; /OC is a layer and means nothing else.
                guard let p = entry.marked.properties, entry.marked.tag != "OC" else { continue }
                entry.node.dirtyMarked[entry.op] = p
            }
        }
        // The structure tree names the sequences of the page itself; what a form paints belongs to the one that calls it.
        guard let last = openMarks.last(where: { $0.node === root && $0.marked.mcid != nil }), let mcid = last.marked.mcid else { return }
        let (total, gone) = marked[mcid] ?? (0, 0)
        marked[mcid] = (total + 1, gone + (removed ? 1 : 0))
    }
}
