import Foundation

// Twin of windows/LazyPDF.Core/Editing/EditScan.cs: walks a page once and records every glyph, image and path with the
// stream and operation it came from. Units, visits and glyphs are compared and hashed by identity, as the C# classes are.

/// A content stream being edited: the page's content as one piece, or one form XObject.
final class ContentUnit: Hashable {
    private var scanned: OpStates?

    /// Nil for the page.
    let form: PdfStream?
    let data: [UInt8]
    let operations: [ContentOperation]

    init(_ form: PdfStream?, _ data: [UInt8], _ operations: [ContentOperation]) {
        self.form = form
        self.data = data
        self.operations = operations
    }

    var states: OpStates {
        if let scanned { return scanned }
        let result = OpStates.scan(operations, inherited)
        scanned = result
        return result
    }

    /// For a form: the state at the `Do` of its first visit.
    var inherited: OpState?

    /// How many times the walk ran this stream: a form painted twice is edited for both.
    var visits = 0

    static func == (a: ContentUnit, b: ContentUnit) -> Bool { a === b }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// One run of a form XObject inside the walk: where its `Do` is and what encloses it.
final class FormVisit: Hashable {
    private var scanned: OpStates?

    let form: PdfStream
    let parent: FormVisit?
    let parentUnit: ContentUnit
    let doOperation: Int
    let name: String?
    let unit: ContentUnit
    let inherited: OpState

    init(_ form: PdfStream, _ parent: FormVisit?, _ parentUnit: ContentUnit, _ doOperation: Int, _ name: String?, _ unit: ContentUnit, _ inherited: OpState) {
        self.form = form
        self.parent = parent
        self.parentUnit = parentUnit
        self.doOperation = doOperation
        self.name = name
        self.unit = unit
        self.inherited = inherited
    }

    /// The scan of the form from the state at this visit's `Do`.
    var states: OpStates {
        if let scanned { return scanned }
        let result = inherited === unit.inherited ? unit.states : OpStates.scan(unit.operations, inherited)
        scanned = result
        return result
    }

    var chain: [PdfStream] {
        guard let parent else { return [form] }
        return parent.chain + [form]
    }

    static func == (a: FormVisit, b: FormVisit) -> Bool { a === b }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Marked content with /ActualText: its glyphs stand for the text of the span, so they are cut and restyled together.
final class ActualSpan {
    let unit: ContentUnit
    let visit: FormVisit?

    /// The operation that opens the span.
    let op: Int
    let marked: MarkedContent

    var members: [EditGlyph] = []

    init(_ unit: ContentUnit, _ visit: FormVisit?, _ op: Int, _ marked: MarkedContent) {
        self.unit = unit
        self.visit = visit
        self.op = op
        self.marked = marked
    }
}

/// A shown glyph with everything needed to find and rewrite its bytes.
final class EditGlyph: Hashable {
    let unit: ContentUnit
    let font: PdfFont
    var character: FontChar

    init(unit: ContentUnit, font: PdfFont, character: FontChar) {
        self.unit = unit
        self.font = font
        self.character = character
    }

    var visit: FormVisit?
    var op = 0
    var element = 0
    var offset = 0
    var length = 0
    var sequence = 0

    var text = ""
    var matrix = PdfMatrix.identity
    var ctm = PdfMatrix.identity
    var textMatrix = PdfMatrix.identity
    var textLineMatrix = PdfMatrix.identity
    var bounds = PdfRect(0, 0, 0, 0)
    var quad = TextQuad.zero

    var fontSize = 0.0
    var scale = 1.0
    var charSpacing = 0.0
    var wordSpacing = 0.0
    var rise = 0.0
    var leading = 0.0
    var advance = 0.0
    var renderMode = 0
    var color = RgbColor(0, 0, 0)
    var hasActualText = false

    /// The /ActualText span the glyph is in, when the editor can take it as a unit: the span and the glyph are in the same stream.
    var span: ActualSpan?

    /// The /ActualText spans inside `span` that also hold the glyph, outermost first.
    var inner: [ActualSpan] = []

    /// Glyphs drawn again at the same place, which go with it.
    var twins: [EditGlyph] = []

    /// The size in user space units the glyph is drawn at.
    var userSize: Double { (matrix.c * matrix.c + matrix.d * matrix.d).squareRoot() }

    /// Where text space lengths along the line become user space lengths.
    var unitX: Double {
        let m = textMatrix.multiply(ctm)
        return (pow(m.a, 2) + pow(m.b, 2)).squareRoot()
    }

    var origin: (x: Double, y: Double) { (matrix.e, matrix.f) }

    /// The unit vector along the baseline in user space.
    var direction: (x: Double, y: Double) {
        let length = (matrix.a * matrix.a + matrix.b * matrix.b).squareRoot()
        return length < 1e-12 ? (1, 0) : (matrix.a / length, matrix.b / length)
    }

    static func == (a: EditGlyph, b: EditGlyph) -> Bool { a === b }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct ImageRecord {
    let unit: ContentUnit
    let visit: FormVisit?
    let op: Int
    let info: ImageInfo
    let opacity: Double
    let sequence: Int
    let clip: PdfRect
}

struct PathRecord {
    let unit: ContentUnit
    let visit: FormVisit?
    let firstOp: Int
    let paintOp: Int
    let info: PathInfo
    let style: PathStyle
    let sequence: Int
}

final class EditScan: ContentVisitor {
    private static let maxFormSize = 64 << 20
    private static let maxFormOperations = 1_000_000
    private static let pathBuilders: Set<String> = ["m", "l", "c", "v", "y", "h", "re", "W", "W*"]

    private let document: PdfDocument
    private let page: PdfPage
    private var visits: [FormVisit] = []
    private var inPattern = 0
    private var sequence = 0
    private var spans: [ObjectIdentifier: ActualSpan] = [:]

    init(_ document: PdfDocument, _ page: PdfPage) {
        self.document = document
        self.page = page
        let data = page.contents()
        let unit = ContentUnit(nil, data, ContentParser.parse(data))
        unit.visits = 1
        pageUnit = unit
        super.init()
    }

    let pageUnit: ContentUnit
    var forms: [ObjectIdentifier: ContentUnit] = [:]
    var glyphs: [EditGlyph] = []
    var images: [ImageRecord] = []
    var paths: [PathRecord] = []

    private var current: ContentUnit { visits.last?.unit ?? pageUnit }
    private var visit: FormVisit? { visits.last }

    override func beginForm(_ context: ContentContext, _ form: FormInfo) {
        if form.isPattern || inPattern > 0 {
            inPattern += 1
            return
        }
        let unit: ContentUnit
        if let known = forms[ObjectIdentifier(form.stream)] {
            unit = known
        } else {
            var data: [UInt8] = []
            var operations: [ContentOperation] = []
            do {
                data = try document.data(form.stream, Self.maxFormSize)
                operations = try ContentParser.parse(data, Self.maxFormOperations)
            } catch {
                // A form that cannot be read has no operations; only PdfReadException comes out of these two.
            }
            unit = ContentUnit(form.stream, data, operations)
            forms[ObjectIdentifier(form.stream)] = unit
        }
        unit.visits += 1
        let parent = visit
        let inherited = (parent?.states ?? pageUnit.states).at(context.operatorIndex)
            .forForm({ op in self.sameResource(op, parent, form.stream) }, isTransparencyGroup(form.stream))
        if unit.visits == 1 { unit.inherited = inherited }
        visits.append(FormVisit(form.stream, parent, current, context.operatorIndex, form.name, unit, inherited))
    }

    private func isTransparencyGroup(_ form: PdfStream) -> Bool {
        guard let group = document.dict(form.dictionary, "Group") else { return false }
        return (document.resolve(group["S"]) as? PdfName)?.value == "Transparency"
    }

    // A name in an operator inherited from the caller means what the form's own resources say it means (7.8.3), so
    // it can be replayed in the form only where they give the same object.
    private func sameResource(_ op: ContentOperation, _ caller: FormVisit?, _ form: PdfStream) -> Bool {
        let category: String
        let name: PdfObject?
        switch op.operator {
        case "Tf": (category, name) = ("Font", op.operands.first)
        case "gs": (category, name) = ("ExtGState", op.operands.first)
        case "cs", "CS": (category, name) = ("ColorSpace", op.operands.first)
        case "sc", "scn", "SC", "SCN": (category, name) = ("Pattern", op.operands.last)
        default: (category, name) = ("", nil)
        }
        guard let key = (name as? PdfName)?.value, category != "" else { return true }
        if category == "ColorSpace" && (key == "DeviceGray" || key == "DeviceRGB" || key == "DeviceCMYK" || key == "Pattern") { return true }
        guard let own = document.dict(form.dictionary, "Resources") else { return true }
        return find(own, category, key) === find(callerResources(caller), category, key)
    }

    private func callerResources(_ caller: FormVisit?) -> PdfDictionary? {
        guard let caller else { return page.resources }
        return document.dict(caller.form.dictionary, "Resources") ?? callerResources(caller.parent)
    }

    private func find(_ resources: PdfDictionary?, _ category: String, _ name: String) -> PdfObject? {
        guard let entries = document.dict(resources, category), entries.containsKey(name) else { return nil }
        return document.resolve(entries[name])
    }

    override func endForm(_ context: ContentContext, _ form: FormInfo) {
        if inPattern > 0 {
            inPattern -= 1
            return
        }
        visits.removeLast()
    }

    override func beginMarked(_ context: ContentContext, _ marked: MarkedContent) {
        if inPattern == 0, marked.properties?.containsKey("ActualText") == true {
            spans[ObjectIdentifier(marked)] = ActualSpan(current, visit, context.operatorIndex, marked)
        }
    }

    override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
        if inPattern > 0 { return }
        let state = context.state
        let m = glyph.matrix
        var ascent = glyph.font.ascent > 0 ? Swift.min(glyph.font.ascent / 1000, 1.1) : 0.8
        let descent = glyph.font.descent < 0 ? Swift.max(glyph.font.descent / 1000, -0.4) : -0.2
        ascent = Swift.max(ascent, 0.5)
        let width = Swift.max(glyph.character.width / 1000, 0)
        let p0 = m.transform(0, descent)
        let p1 = m.transform(width, descent)
        let p2 = m.transform(width, ascent)
        let p3 = m.transform(0, ascent)
        let g = EditGlyph(unit: current, font: glyph.font, character: glyph.character)
        g.visit = visit
        g.op = context.operatorIndex
        g.element = glyph.element
        g.offset = glyph.offset
        g.length = glyph.character.length
        g.sequence = sequence
        sequence += 1
        g.text = glyph.unicode ?? ""
        g.matrix = m
        g.ctm = state.ctm
        g.textMatrix = context.textMatrix
        g.textLineMatrix = context.textLineMatrix
        g.bounds = glyph.bounds
        g.quad = TextQuad(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)
        g.fontSize = state.fontSize
        g.scale = state.horizontalScale
        g.charSpacing = state.charSpacing
        g.wordSpacing = state.wordSpacing
        g.rise = state.rise
        g.leading = state.leading
        g.advance = glyph.advance
        g.renderMode = state.renderMode
        g.color = (state.renderMode == 1 ? state.strokeColor : state.fillColor).rgb
        g.hasActualText = context.marked.contains { $0.properties?.containsKey("ActualText") == true }
        let enclosing = context.marked.compactMap { self.spans[ObjectIdentifier($0)] }
        if let span = enclosing.first, span.unit === current, span.visit === visit {
            g.span = span
            g.inner = enclosing.dropFirst().filter { $0.unit === current && $0.visit === visit }
            span.members.append(g)
        }
        glyphs.append(g)
    }

    override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
        if inPattern > 0 { return }
        images.append(ImageRecord(unit: current, visit: visit, op: context.operatorIndex, info: image, opacity: context.state.fillAlpha,
                                  sequence: sequence, clip: context.state.clip))
        sequence += 1
    }

    override func paintPath(_ context: ContentContext, _ path: PathInfo) {
        if inPattern > 0 || !(path.fill || path.stroke) { return }
        let state = context.state
        let style = PathStyle(fill: state.fillColor.rgb, stroke: state.strokeColor.rgb, lineWidth: state.lineWidth,
                              opacity: path.fill ? state.fillAlpha : state.strokeAlpha, ctm: state.ctm)
        let ops = current.operations
        let paint = context.operatorIndex
        var first = paint
        while first > 0 && Self.pathBuilders.contains(ops[first - 1].operator) { first -= 1 }
        paths.append(PathRecord(unit: current, visit: visit, firstOp: first, paintOp: paint, info: path, style: style, sequence: sequence))
        sequence += 1
    }
}

/// What a path was painted with.
struct PathStyle {
    let fill: RgbColor
    let stroke: RgbColor
    let lineWidth: Double
    let opacity: Double
    let ctm: PdfMatrix
}
