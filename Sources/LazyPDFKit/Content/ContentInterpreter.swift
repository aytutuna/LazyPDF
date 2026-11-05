import Foundation

// Twin of windows/LazyPDF.Core/Content/ContentInterpreter.cs: walks the operations of a page or form with the full
// graphics state (ISO 32000-1 8, 9) and reports glyphs, paths, images, shadings and marked content to a
// `ContentVisitor`. Form XObjects and tiling patterns are entered, each once per use for forms and once per run for
// patterns. Everything is bounded: the q stack, form depth, the number of operations and the size of a path; when
// the operation limit stops a run, `isTruncated` says so. The interpreter keeps no state between runs except what it
// caches, but is not thread safe.
//
// The C# class is partial; the parts are extensions in this folder. Swift keeps stored properties in the type's own
// declaration, so the state of every part is listed here, internal instead of private.

public final class ContentInterpreter {
    static let maxStack = 256
    static let maxFormDepth = 20
    static let maxSegments = 1_000_000
    static let maxCachedForms = 1024
    static let maxOperations = 10_000_000
    static let maxFormOperations = 1_000_000
    static let maxCachedOperations = 4_000_000
    static let maxFormSize = 64 << 20
    static let maxMarkedDepth = 1024

    static let unbounded = PdfRect(-1e9, -1e9, 1e9, 1e9)

    /// What a Dictionary<PdfObject, ...> compares by in the C#: a name by its value, anything else by identity.
    enum SpaceKey: Hashable {
        case name(String)
        case object(ObjectIdentifier)
    }

    let document: PdfDocument
    var formOperations: [ObjectIdentifier: (stream: PdfStream, operations: [ContentOperation])] = [:]
    var colorSpaces: [SpaceKey: (definition: PdfObject, space: ColorSpaceInfo)] = [:]
    // Kept for the interpreter's life, as the C# ConditionalWeakTable keeps a font while its dictionary lives:
    // PdfFont.get holds weakly, and a font built again on every Tf would cost far more than the Tf's one operation.
    var fonts: [ObjectIdentifier: PdfFont] = [:]
    var resources: [PdfDictionary?] = []
    var activeForms = Set<ObjectIdentifier>()
    var walkedPatterns = Set<ObjectIdentifier>()
    var visitor = ContentVisitor()
    var context: ContentContext
    var state = GraphicsState()
    var stack: [GraphicsState] = []
    var overflow = 0
    var stackFloor = 0
    var markedFloor = 0
    var base = PdfMatrix.identity
    var tm = PdfMatrix.identity
    var tlm = PdfMatrix.identity
    var budget = 0
    var cachedOperations = 0
    var fallbackFont: PdfFont?

    // Paths (ContentInterpreter.Graphics)
    var path: [PathSegment] = []
    var curX = 0.0, curY = 0.0, startX = 0.0, startY = 0.0
    var pendingClip = 0

    public init(_ document: PdfDocument) {
        let initial = GraphicsState()
        self.document = document
        state = initial
        context = ContentContext(document, initial)
    }

    /// Whether tiling pattern cells are run when something is painted with the pattern.
    public var walkPatterns = true

    /// The last run stopped at the operation limit.
    public internal(set) var isTruncated = false

    /// Runs a page's content, the user space of the page as the starting space and its crop box as the clip.
    public func run(_ page: PdfPage, _ visitor: ContentVisitor) {
        begin(visitor, page.cropBox)
        resources.append(page.resources)
        execute(ContentParser.parse(page.contents()))
    }

    /// Runs a form XObject as if it were painted at the origin of the starting space, with `matrix` applied first.
    public func run(_ form: PdfStream, _ visitor: ContentVisitor, _ matrix: PdfMatrix? = nil) {
        begin(visitor, Self.unbounded)
        state.ctm = matrix ?? PdfMatrix.identity
        base = state.ctm
        enterForm(form, nil, nil)
    }

    private func begin(_ visitor: ContentVisitor, _ clip: PdfRect) {
        self.visitor = visitor
        state = GraphicsState()
        state.clip = clip
        context = ContentContext(document, state)
        stack = []
        overflow = 0
        stackFloor = 0
        markedFloor = 0
        base = PdfMatrix.identity
        tm = PdfMatrix.identity
        tlm = PdfMatrix.identity
        budget = Self.maxOperations
        isTruncated = false
        resources.removeAll()
        activeForms.removeAll()
        walkedPatterns.removeAll()
        resetPath()
    }

    func execute(_ operations: [ContentOperation]) {
        let (outerMarkedFloor, outerStackFloor, outerOverflow) = (markedFloor, stackFloor, overflow)
        markedFloor = context.marked.count
        stackFloor = stack.count
        overflow = 0
        for i in 0..<operations.count {
            budget -= 1
            if budget < 0 {
                isTruncated = true
                break
            }
            context.operatorIndex = i
            context.operation = operations[i]
            dispatch(operations[i])
        }
        while context.marked.count > markedFloor { endMarkedContent() }
        (markedFloor, stackFloor, overflow) = (outerMarkedFloor, outerStackFloor, outerOverflow)
    }

    private func dispatch(_ op: ContentOperation) {
        switch op.operator {
        case "q": push()
        case "Q": pop()
        case "cm": concat(op)
        case "w": if let w = number(op) { state.lineWidth = w }
        case "J": if let cap = number(op) { state.lineCap = Int(saturating32: cap) }
        case "j": if let join = number(op) { state.lineJoin = Int(saturating32: join) }
        case "M": if let miter = number(op) { state.miterLimit = miter }
        case "d": setDash(op)
        case "gs": setExtGState(op)

        case "m", "l", "c", "v", "y", "h", "re": buildPath(op)
        case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n": paintPath(op.operator)
        case "W": pendingClip = 1
        case "W*": pendingClip = 2

        case "g", "G", "rg", "RG", "k", "K": setDeviceColor(op)
        case "cs", "CS": setColorSpace(op)
        case "sc", "scn", "SC", "SCN": setColor(op)

        case "BT":
            tm = PdfMatrix.identity
            tlm = PdfMatrix.identity
            syncText()
        case "Tc": if let tc = number(op) { state.charSpacing = tc }
        case "Tw": if let tw = number(op) { state.wordSpacing = tw }
        case "Tz": if let tz = number(op) { state.horizontalScale = tz / 100 }
        case "TL": if let tl = number(op) { state.leading = tl }
        case "Tf": setFont(op)
        case "Tr": if let tr = number(op) { state.renderMode = Int(saturating32: tr) }
        case "Ts": if let ts = number(op) { state.rise = ts }
        case "Td", "TD", "Tm", "T*": moveText(op)
        case "Tj", "TJ", "'", "\"": showText(op)

        case "Do": paint(op)
        case "BI": paintInlineImage(op)
        case "sh": paintShading(op)
        case "BMC", "BDC": beginMarkedContent(op)
        case "EMC": endMarkedContent()
        default: break
        }
    }

    func number(_ op: ContentOperation) -> Double? {
        guard let n = op.operands.last as? PdfNumber, n.value.isFinite else { return nil }
        return n.value
    }

    // The last `count` operands, which all have to be numbers.
    func numbers(_ op: ContentOperation, _ count: Int) -> [Double]? {
        let available = op.operands.count
        if available < count { return nil }
        var values: [Double] = []
        values.reserveCapacity(count)
        for i in 0..<count {
            guard let number = op.operands[available - count + i] as? PdfNumber, number.value.isFinite else { return nil }
            values.append(number.value)
        }
        return values
    }

    private func push() {
        if stack.count >= Self.maxStack {
            overflow += 1
            return
        }
        stack.append(state.clone())
    }

    private func pop() {
        if overflow > 0 {
            overflow -= 1
            return
        }
        if stack.count <= stackFloor { return }
        guard let top = stack.popLast() else { return }
        state = top
        context.state = state
    }

    private func concat(_ op: ContentOperation) {
        guard let m = numbers(op, 6) else { return }
        state.ctm = PdfMatrix(m[0], m[1], m[2], m[3], m[4], m[5]).multiply(state.ctm)
    }

    /// The resource `name` of a category, looked up in the current resources and then those of the enclosing streams.
    func findResource(_ category: String, _ name: String) -> PdfObject? {
        for i in stride(from: resources.count - 1, through: 0, by: -1) {
            if let entries = document.dict(resources[i], category), entries.containsKey(name) { return document.resolve(entries[name]) }
        }
        return nil
    }

    func nameOperand(_ op: ContentOperation) -> String? { (op.operands.first as? PdfName)?.value }

    /// The font for a font dictionary, kept for this interpreter.
    func font(_ dictionary: PdfDictionary) -> PdfFont {
        let key = ObjectIdentifier(dictionary)
        if let known = fonts[key] { return known }
        let font = PdfFont.get(document, dictionary)
        fonts[key] = font
        return font
    }
}
