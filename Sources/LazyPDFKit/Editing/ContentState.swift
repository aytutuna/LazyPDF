import Foundation

// Twin of windows/LazyPDF.Core/Editing/ContentState.cs: the operators that set the graphics state in force before one
// operation of a content stream, kept as the operations themselves so that an edit can write them back to restore what
// it changed, and the scan of a content stream that records them.

struct StateParts: OptionSet {
    let rawValue: Int

    static let font = StateParts(rawValue: 1)
    static let charSpacing = StateParts(rawValue: 2)
    static let wordSpacing = StateParts(rawValue: 4)
    static let scale = StateParts(rawValue: 8)
    static let leading = StateParts(rawValue: 16)
    static let mode = StateParts(rawValue: 32)
    static let rise = StateParts(rawValue: 64)
    static let fill = StateParts(rawValue: 128)
    static let stroke = StateParts(rawValue: 256)
    static let states = StateParts(rawValue: 512)
    static let text: StateParts = [.font, .charSpacing, .wordSpacing, .scale, .leading, .mode, .rise]
    static let all: StateParts = [.text, .fill, .stroke, .states]
}

/// Instances are never changed after the scan.
final class OpState {
    var font: ContentOperation?
    var charSpacing: ContentOperation?
    var wordSpacing: ContentOperation?
    var scale: ContentOperation?
    var leading: ContentOperation?
    var mode: ContentOperation?
    var rise: ContentOperation?
    var fill: [ContentOperation] = []
    var stroke: [ContentOperation] = []
    var states: [ContentOperation] = []
    var ctm = PdfMatrix.identity

    /// Open `q` count, those past the interpreter's stack included.
    var depth = 0
    var inText = false

    /// A font or colours the caller set that the form cannot name, so that no operator of the form can bring them back.
    var lost: StateParts = []

    /// What a form starts with when it is painted from this state: everything but the stack, the text object and the matrix.
    /// An operator that names a resource is kept only where `resolves` says the form finds the same one.
    /// A transparency group starts with full opacity, the Normal blend mode and no soft mask whatever the caller set (11.6.6),
    /// and the caller's graphics state already applies to the group as a whole, so none of it is inherited.
    func forForm(_ resolves: (ContentOperation) -> Bool, _ transparencyGroup: Bool) -> OpState {
        with { s in
            s.depth = 0
            s.inText = false
            s.ctm = .identity
            if let font = s.font, !resolves(font) {
                s.font = nil
                s.lost.insert(.font)
            }
            if !s.fill.allSatisfy(resolves) {
                s.fill = []
                s.lost.insert(.fill)
            }
            if !s.stroke.allSatisfy(resolves) {
                s.stroke = []
                s.lost.insert(.stroke)
            }
            s.states = transparencyGroup ? [] : s.states.filter(resolves)
        }
    }

    func with(_ change: (OpState) -> Void) -> OpState {
        let copy = OpState()
        copy.font = font
        copy.charSpacing = charSpacing
        copy.wordSpacing = wordSpacing
        copy.scale = scale
        copy.leading = leading
        copy.mode = mode
        copy.rise = rise
        copy.fill = fill
        copy.stroke = stroke
        copy.states = states
        copy.ctm = ctm
        copy.depth = depth
        copy.inText = inText
        copy.lost = lost
        change(copy)
        return copy
    }

    /// Writes the operators that bring a state back to this one for the chosen parts; a part never set is written as its default.
    func replay(_ w: ContentWriter, _ parts: StateParts) throws {
        if !parts.intersection(lost).isEmpty {
            throw EditConflictException(parts.intersection(lost).contains(.font) ? EditingText.fontSetOutside : EditingText.colorOutside)
        }
        if parts.contains(.font), let font { w.add(font) }
        put(w, parts, .charSpacing, charSpacing, "Tc", 0)
        put(w, parts, .wordSpacing, wordSpacing, "Tw", 0)
        put(w, parts, .scale, scale, "Tz", 100)
        put(w, parts, .leading, leading, "TL", 0)
        put(w, parts, .mode, mode, "Tr", 0)
        put(w, parts, .rise, rise, "Ts", 0)
        if parts.contains(.fill) { putColor(w, fill, "g") }
        if parts.contains(.stroke) { putColor(w, stroke, "G") }
        if parts.contains(.states) { for gs in states { w.add(gs) } }
    }

    private func put(_ w: ContentWriter, _ parts: StateParts, _ part: StateParts, _ op: ContentOperation?, _ name: String, _ fallback: Double) {
        if !parts.contains(part) { return }
        if let op { w.add(op) } else { w.op(name, fallback) }
    }

    private func putColor(_ w: ContentWriter, _ ops: [ContentOperation], _ gray: String) {
        if ops.isEmpty { w.op(gray, 0) }
        for op in ops { w.add(op) }
    }
}

/// The scan of a content stream: the state before each operation, and after the last.
final class OpStates {
    private static let maxStack = 256

    private static let topLevelSetters: Set<String> =
        ["cm", "gs", "Tc", "Tw", "\"", "Tz", "Tr", "Ts", "d", "J", "j", "w", "M", "i", "ri", "W", "W*"]

    private init(_ before: [OpState], _ end: OpState, _ baseCtm: PdfMatrix, _ stray: Bool, _ setsTopLevel: Bool) {
        self.before = before
        self.end = end
        self.baseCtm = baseCtm
        self.stray = stray
        self.setsTopLevel = setsTopLevel
    }

    let before: [OpState]
    let end: OpState

    /// The matrix in force once every open `q` has been closed.
    let baseCtm: PdfMatrix

    /// A `Q` with nothing to pop: a `q` written ahead of the stream would be popped by it.
    let stray: Bool

    /// An operator outside every `q` sets state that outlives the stream (8.4.2).
    let setsTopLevel: Bool

    /// The state before operation `index`; the end state for an index past the last.
    func at(_ index: Int) -> OpState { index < before.count ? before[index] : end }

    /// Follows the stack the way the interpreter does: a `Q` with nothing to pop is ignored.
    /// A form starts from the state it is painted in (8.10.1), so a part it never sets is the caller's, not the default.
    static func scan(_ ops: [ContentOperation], _ inherited: OpState? = nil) -> OpStates {
        var before: [OpState] = []
        before.reserveCapacity(ops.count)
        var current = inherited ?? OpState()
        var stack: [OpState] = []
        var overflow = 0
        var stray = false
        var setsTopLevel = false
        for op in ops {
            before.append(current)
            if stack.isEmpty && overflow == 0 && topLevelSetters.contains(op.operator) { setsTopLevel = true }
            switch op.operator {
            case "q":
                if stack.count >= maxStack { overflow += 1 } else { stack.append(current) }
                let depth = stack.count + overflow
                current = current.with { $0.depth = depth }
            case "Q":
                if overflow > 0 {
                    overflow -= 1
                } else if let top = stack.last {
                    let inText = current.inText
                    current = top.with { $0.inText = inText }
                    stack.removeLast()
                } else {
                    stray = true
                }
                let depth = stack.count + overflow
                current = current.with { $0.depth = depth }
            case "cm":
                if let m = matrix(op) { current = current.with { $0.ctm = m.multiply($0.ctm) } }
            case "BT": current = current.with { $0.inText = true }
            case "ET": current = current.with { $0.inText = false }
            case "Tf":
                current = current.with { s in
                    s.font = op
                    s.lost.remove(.font)
                }
            case "Tc": current = current.with { $0.charSpacing = op }
            case "Tw": current = current.with { $0.wordSpacing = op }
            case "\"" where op.operands.count >= 3:
                let word = ContentOperation("Tw", [op.operands[0]], op.start, op.end)
                let chars = ContentOperation("Tc", [op.operands[1]], op.start, op.end)
                current = current.with { s in
                    s.wordSpacing = word
                    s.charSpacing = chars
                }
            case "Tz": current = current.with { $0.scale = op }
            case "TL": current = current.with { $0.leading = op }
            case "Tr": current = current.with { $0.mode = op }
            case "Ts": current = current.with { $0.rise = op }
            case "g", "rg", "k", "cs":
                current = current.with { s in
                    s.fill = [op]
                    s.lost.remove(.fill)
                }
            case "G", "RG", "K", "CS":
                current = current.with { s in
                    s.stroke = [op]
                    s.lost.remove(.stroke)
                }
            case "sc", "scn": current = current.with { $0.fill = colored($0.fill, op) }
            case "SC", "SCN": current = current.with { $0.stroke = colored($0.stroke, op) }
            case "gs": current = current.with { $0.states = Array($0.states.suffix(15)) + [op] }
            default: break
            }
        }
        return OpStates(before, current, stack.first?.ctm ?? current.ctm, stray, setsTopLevel)
    }

    // A colour operator after its space operator replays together with it.
    private static func colored(_ ops: [ContentOperation], _ op: ContentOperation) -> [ContentOperation] {
        ops.isEmpty ? [op] : [ops[0], op]
    }

    private static func matrix(_ op: ContentOperation) -> PdfMatrix? {
        if op.operands.count < 6 { return nil }
        var n: [Double] = []
        for i in 0..<6 {
            guard let number = op.operands[op.operands.count - 6 + i] as? PdfNumber, number.value.isFinite else { return nil }
            n.append(number.value)
        }
        return PdfMatrix(n[0], n[1], n[2], n[3], n[4], n[5])
    }
}
