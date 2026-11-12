import Foundation

// Twin of windows/LazyPDF.Core/Redaction/ContentRewriter.cs: applies what a `RedactionScan` found to the bytes of a content
// stream. Everything the scan did not touch is copied as it was. A form that has to change is copied, the copy edited and the
// call to it pointed at the copy, so other uses of the form keep what it shows.

final class ContentRewriter {
    private static let maxFormOperations = 1_000_000
    private static let maxFormSize = 64 << 20
    // What a form is drawn from (8.10); /AF, /Metadata, /PieceInfo, /OPI and the like are not copied along.
    private static let formKept = ["Type", "Subtype", "FormType", "BBox", "Matrix", "Resources", "Group", "OC", "StructParent", "StructParents"]
    private static let construction = ["m", "l", "c", "v", "y", "h", "re"]
    private static let paints = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"]

    private struct Cut {
        let start: Int
        let end: Int
        let text: String
    }

    /// What a shift in a show array is worth (9.3.4): everything but the size in `face`, and the size times the horizontal
    /// scale in `unit`, 0 when it is not known.
    private struct Scale {
        let face: String
        let unit: Double
    }

    private let document: PdfDocument
    private let images: ImageRedactor

    init(_ document: PdfDocument, _ images: ImageRedactor) {
        self.document = document
        self.images = images
    }

    /// The images and forms that were copied, for the tag tree: an item that still names the original would keep it.
    var replaced = RedactionObjects.Identities()

    /// How many placements were removed whole because the picture could not be cut.
    private(set) var wholeImages = 0

    /// A resource dictionary of one's own to add names to: the categories are copied, what they point at is shared.
    func privateResources(_ resources: PdfDictionary?) -> PdfDictionary {
        let copy = resources?.copy() ?? PdfDictionary()
        for (key, value) in copy.entries {
            if let category = document.resolve(value) as? PdfDictionary { copy[key] = category.copy() }
        }
        return copy
    }

    /// The new content of the stream. `owner` is the page or form dictionary that gets the private resources.
    func rewrite(_ node: ScanNode, _ source: [UInt8], _ owner: PdfDictionary, _ inherited: PdfDictionary?, _ isForm: Bool) throws -> [UInt8] {
        let operations = try isForm ? ContentParser.parse(source, Self.maxFormOperations) : ContentParser.parse(source)
        let resources = privateResources(document.dict(owner, "Resources") ?? inherited)
        owner["Resources"] = resources
        var cuts: [Cut] = []
        var leads: [Int: Double] = [:]
        var emptied = Set<Int>()
        var scales: [Scale]?

        func replace(_ index: Int, _ text: String) {
            cuts.append(Cut(start: operations[index].start, end: operations[index].end, text: text))
        }

        for (index, edit) in node.edits.sorted(by: { $0.key < $1.key }) {
            let op = operations[index]
            switch edit {
            case is DeleteEdit:
                replace(index, "")
            case let s as SurroundEdit:
                replace(index, s.before + Latin1.string(Array(source[op.start..<op.end])) + s.after)
            case let t as TextEdit:
                if scales == nil { scales = self.scales(operations, resources) }
                replace(index, Self.showText(operations, scales ?? [], index, t, &leads, &emptied))
            case let p as PathEdit:
                Self.rewritePath(operations, index, p, &cuts)
            case let image as ImageEdit:
                replaced.insert(image.image)
                for key in ["SMask", "Mask"] {
                    if let mask = document.stream(image.image.dictionary, key) { replaced.insert(mask) }
                }
                if let reference = images.redact(image.image, image.areas, image.matrix) {
                    replace(index, Self.use(ContentResources.add(document, resources, "XObject", reference, "Rd")))
                } else {
                    wholeImages += 1
                    replace(index, "")
                }
            default:
                break
            }
        }
        for (index, lead) in leads.sorted(by: { $0.key < $1.key }) {
            if operations[index].operands.isEmpty { continue }
            let op = operations[index]
            cuts.append(Cut(start: op.start, end: op.end, text: Self.show(Self.merge([PdfNumber(lead)] + Self.elements(op)))))
        }
        Self.mergePositions(operations, emptied, &cuts)
        Self.dropMatrices(operations, emptied, &cuts)
        Self.mergeMatrices(operations, emptied, &cuts)
        for (index, child) in node.children.sorted(by: { $0.key < $1.key }) {
            guard child.hasEdits, let form = child.form else { continue }
            replaced.insert(form)
            let copy = PdfDictionary()
            for key in Self.formKept {
                if let value = form.dictionary[key] { copy[key] = value }
            }
            var bytes: [UInt8]
            do {
                bytes = try rewrite(child, document.data(form, Self.maxFormSize), copy, resources, true)
            } catch is PdfReadException {
                replace(index, "")
                continue
            }
            bytes = RedactionResources.dropIdleFonts(bytes)
            let walk = RedactionWalk(document)
            if walk.content(copy, bytes) { RedactionResources.rebuild(document, copy, walk) }
            copy["Filter"] = PdfName("FlateDecode")
            copy.remove("DecodeParms")
            let reference = try document.add(PdfStream(copy, data: PdfFilterEncoders.flate(bytes)))
            replace(index, Self.use(ContentResources.add(document, resources, "XObject", reference, "Rd")))
        }
        for (index, described) in node.dirtyMarked.sorted(by: { $0.key < $1.key }) {
            let op = operations[index]
            if op.operands.count < 2 { continue }
            // Only the number that ties the sequence to the tag tree stays: any other key may describe what was taken out.
            let plain = PdfDictionary()
            if let mcid = described["MCID"] { plain["MCID"] = mcid }
            cuts.append(Cut(start: op.start, end: op.end, text: "\(op.operands[0]) \(plain) BDC"))
        }
        // A point has no extent to say what it describes, so on a stream that lost something none keeps a description.
        if node.hasEdits {
            for op in operations where op.operator == "DP" && op.operands.count == 2 && op.operands[0] is PdfName
                && (op.operands[1] is PdfDictionary || op.operands[1] is PdfName) {
                cuts.append(Cut(start: op.start, end: op.end, text: "\(op.operands[0]) \(PdfDictionary()) DP"))
            }
        }

        var output: [UInt8] = []
        var at = 0
        for (_, cut) in cuts.enumerated().sorted(by: { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }) {
            if cut.start < at || cut.start > source.count || cut.end > source.count { continue }
            output.append(contentsOf: source[at..<cut.start])
            output.append(contentsOf: Latin1.bytes(cut.text + "\n"))
            at = cut.end
        }
        output.append(contentsOf: source[at...])
        return output
    }

    private static func use(_ name: String) -> String { "\(PdfName(name)) Do" }

    // The construction operators of the path go one by one: colour and state operators may sit between
    // them and the paint, and have to stay. The new outline is written where the paint was. The rule of
    // a clip is the one of its own W or W*, not of the paint operator that follows (8.5.4).
    private static func rewritePath(_ operations: [ContentOperation], _ index: Int, _ edit: PathEdit, _ cuts: inout [Cut]) {
        let paint = operations[index]
        var evenOdd = false
        var i = index - 1
        while i >= 0 && !paints.contains(operations[i].operator) {
            defer { i -= 1 }
            if !construction.contains(operations[i].operator) && operations[i].operator != "W" && operations[i].operator != "W*" { continue }
            evenOdd = evenOdd || operations[i].operator == "W*"
            cuts.append(Cut(start: operations[i].start, end: operations[i].end, text: ""))
        }
        var text = ""
        if let back = edit.ctm.invert() {
            text = RedactionPaths.polygons(edit.remains.map { p in p.map { back.transform($0.x, $0.y) } })
        }
        if edit.clips {
            // A clip with nothing left of it still has to clip: to a point, so that what it guarded stays hidden.
            if text.isEmpty { text = "0 0 m\n0 0 l\nh\n" }
            text += (evenOdd ? "W*" : "W") + " n"
        } else if !text.isEmpty {
            text += paint.operator
        }
        cuts.append(Cut(start: paint.start, end: paint.end, text: text))
    }

    private static let over = -1
    private static let keepShift = -2

    // The patch writes one shift for a run of removed glyphs. A shift at the end of the operator moves to the
    // front of the next show on the same line, so that a run over several operators keeps its total and no
    // width per operator; at the end of a line, when the next show starts from a position of its own, it goes.
    private static func showText(_ operations: [ContentOperation], _ scales: [Scale], _ index: Int, _ edit: TextEdit,
                                 _ leads: inout [Int: Double], _ emptied: inout Set<Int>) -> String {
        let op = operations[index]
        let patch = ShowPatch(op)
        var run: (element: Int, start: Int, end: Int, adjust: Double)?
        func flush() {
            guard let r = run else { return }
            patch.cut(r.element, r.start, r.end)
            if r.adjust != 0 { patch.insert(r.element, r.start, [ShowShift(r.adjust)]) }
            run = nil
        }
        let removed = edit.removed.sorted { $0.key.element != $1.key.element ? $0.key.element < $1.key.element : $0.key.offset < $1.key.offset }
        for (key, value) in removed {
            if let r = run, r.element == key.element, r.end == key.offset {
                run = (key.element, r.start, key.offset + value.length, r.adjust + value.adjust)
            } else {
                flush()
                run = (key.element, key.offset, key.offset + value.length, value.adjust)
            }
        }
        flush()

        let written = patch.compile().bytes
        let parsed = ContentParser.parse(written)
        let show = parsed.first { $0.operator == "Tj" || $0.operator == "TJ" }
        var items: [PdfObject] = []
        if let lead = leads.removeValue(forKey: index) { items.append(PdfNumber(lead)) }
        if let show { items.append(contentsOf: elements(show)) }
        items = merge(items)
        let (next, ratio) = nextShow(operations, scales, index)
        if next != keepShift, let last = items.last as? PdfNumber {
            items.removeLast()
            if next >= 0 { leads[next] = (leads[next] ?? 0) + last.value * ratio }
        }
        if (op.operator == "Tj" || op.operator == "TJ") && !items.contains(where: { $0 is PdfString }) { emptied.insert(index) }

        var output = ""
        for part in parsed {
            if part !== show {
                output += Latin1.string(Array(written[part.start..<part.end])) + "\n"
            } else if !items.isEmpty {
                output += Self.show(items) + "\n"
            }
        }
        if show == nil && !items.isEmpty { output += Self.show(items) }
        var scalars = Array(output.unicodeScalars)
        while scalars.last == "\n" { scalars.removeLast() }
        var trimmed = String.UnicodeScalarView()
        trimmed.append(contentsOf: scalars)
        return String(trimmed)
    }

    // What a shift means at each operation: the font size set by the last Tf or by a graphics state that has a font
    // (9.3.4), and the horizontal scale. Q gives back what the q before it held.
    private func scales(_ operations: [ContentOperation], _ resources: PdfDictionary) -> [Scale] {
        var scales: [Scale] = []
        var saved: [(String, Double, Double)] = []
        var face = ""
        var size = 0.0, scale = 1.0
        let states = document.dict(resources, "ExtGState")
        let fonts = document.dict(resources, "Font")
        for op in operations {
            switch op.operator {
            case "q":
                saved.append((face, size, scale))
            case "Q" where !saved.isEmpty:
                (face, size, scale) = saved.removeLast()
            case "Tf":
                // The size sets what a shift is worth; the font only where it can write vertically.
                if op.operands.count == 2, let name = op.operands[0] as? PdfName, let number = op.operands[1] as? PdfNumber,
                   let simple = document.dict(fonts, name.value), document.name(simple, "Subtype") != "Type0" {
                    (face, size) = ("", number.value)
                } else {
                    (face, size) = (op.description, 0)
                }
            case "Tz":
                scale = (op.number(0) ?? 100) / 100
            case "gs" where !op.operands.isEmpty:
                if let state = op.operands[0] as? PdfName, let entries = document.dict(states, state.value), entries.containsKey("Font") {
                    (face, size) = (op.description, 0)
                }
            default:
                break
            }
            scales.append(Scale(face: face, unit: size * scale))
        }
        return scales
    }

    // The next show operator on the same line, or what ends the line first. A shift moves to a show where the font allows
    // it, scaled to the size of that show.
    private static func nextShow(_ operations: [ContentOperation], _ scales: [Scale], _ index: Int) -> (index: Int, ratio: Double) {
        var i = index + 1
        while i < operations.count {
            switch operations[i].operator {
            case "Tj", "TJ":
                let (here, there) = (scales[index], scales[i])
                if here.face != there.face { return (keepShift, 1) }
                if here.unit == there.unit { return (i, 1) }
                return here.unit > 0 && there.unit > 0 ? (i, here.unit / there.unit) : (keepShift, 1)
            case "Td", "TD", "Tm", "T*", "'", "\"", "ET", "BT":
                return (over, 1)
            default:
                break
            }
            i += 1
        }
        return (over, 1)
    }

    private static func elements(_ show: ContentOperation) -> [PdfObject] {
        guard let last = show.operands.last else { return [] }
        return (last as? PdfArray)?.items ?? [last]
    }

    // Shifts that meet become one, the original kerning between two removed runs included.
    private static func merge(_ source: [PdfObject]) -> [PdfObject] {
        var items: [PdfObject] = []
        for item in source {
            if let n = item as? PdfNumber, let last = items.last as? PdfNumber {
                items[items.count - 1] = PdfNumber(last.value + n.value)
            } else {
                items.append(item)
            }
        }
        items.removeAll { ($0 as? PdfNumber)?.value == 0 }
        return items
    }

    private static func show(_ items: [PdfObject]) -> String {
        if items.count == 1, let only = items[0] as? PdfString { return "\(only) Tj" }
        return "\(PdfArray(items)) TJ"
    }

    // A position set between shows that were all taken out has nothing to place: it goes, or is added to the
    // relative move that follows (a Td after a Td or a TD, a TD before a Td, any move before a TD when it is level), or is overwritten by the
    // matrix that follows. A TD also sets the leading (9.4.2), which a dropped one passes on as a TL.
    private static func mergePositions(_ operations: [ContentOperation], _ emptied: Set<Int>, _ cuts: inout [Cut]) {
        var moves: [Int: (x: Double, y: Double)] = [:]
        var text: [Int: String] = [:]
        for p in 0..<operations.count {
            let op = operations[p]
            if !(op.operator == "Td" || op.operator == "TD" || op.operator == "Tm") { continue }
            if op.operator != "Tm" && (op.number(0) == nil || op.number(1) == nil) { continue }
            var q = p + 1
            var any = false
            while q < operations.count {
                if emptied.contains(q) {
                    any = true
                } else if ["Tj", "TJ", "Td", "TD", "Tm", "T*", "'", "\"", "ET", "BT"].contains(operations[q].operator) {
                    break
                }
                q += 1
            }
            if !any { continue }
            let after = q < operations.count ? operations[q].operator : "ET"
            let (px, py): (Double, Double) = op.operator == "Tm" ? (0, 0) : (moves[p].map { ($0.x, $0.y) } ?? (op.number(0) ?? 0, op.number(1) ?? 0))
            if after == "ET" || after == "BT" || after == "Tm" {
                text[p] = op.operator == "TD" ? "\(PdfNumber(0 - py).text) TL" : ""
            } else if (after == "Td" || after == "TD") && op.operator != "Tm", let x = operations[q].number(0), let y = operations[q].number(1), after == "Td" || py == 0 {
                moves[q] = (x + px, y + py)
                text[p] = op.operator == "TD" && after == "Td" ? "\(PdfNumber(0 - py).text) TL" : ""
                text[q] = "\(PdfNumber(x + px).text) \(PdfNumber(y + py).text) \(after)"
            }
        }
        for (index, replacement) in text.sorted(by: { $0.key < $1.key }) {
            cuts.append(Cut(start: operations[index].start, end: operations[index].end, text: replacement))
        }
    }

    // The matrix of a q block that holds nothing but shows taken out places nothing, and left in it gives the
    // position of the removed run. The block restores the state, so nothing after it depends on the matrix.
    private static func dropMatrices(_ operations: [ContentOperation], _ emptied: Set<Int>, _ cuts: inout [Cut]) {
        if emptied.isEmpty { return }
        var enclosing = [Int](repeating: -1, count: operations.count)
        var close: [Int: Int] = [:]
        var open: [Int] = []
        for i in 0..<operations.count {
            enclosing[i] = open.last ?? -1
            if operations[i].operator == "q" {
                open.append(i)
            } else if operations[i].operator == "Q", let top = open.popLast() {
                close[top] = i
            }
        }
        var seen = Set<Int>()
        for shown in emptied.sorted() {
            var q = enclosing[shown]
            while q >= 0, let end = close[q], seen.insert(q).inserted {
                let block = Array(q + 1..<end)
                if block.contains(where: { draws(operations, emptied, $0) }) { break }
                for i in block where operations[i].operator == "cm" {
                    cuts.append(Cut(start: operations[i].start, end: operations[i].end, text: ""))
                }
                q = enclosing[q]
            }
        }
    }

    // Matrices that only separate shows that were taken out gave the position of the removed runs. Those that meet
    // become the one matrix they add up to, or none when it comes to nothing, since each step alone is the width of a run.
    private static func mergeMatrices(_ operations: [ContentOperation], _ emptied: Set<Int>, _ cuts: inout [Cut]) {
        if emptied.isEmpty { return }
        var merged = Set<Int>()
        for a in 0..<operations.count {
            if merged.contains(a) { continue }
            guard var total = matrix(operations[a]) else { continue }
            var shown = false, joined = false
            var b = a + 1
            while b < operations.count {
                if emptied.contains(b) {
                    shown = true
                } else if operations[b].operator == "cm" {
                    guard shown, let next = matrix(operations[b]) else { break }
                    total = total.multiply(next)
                    cuts.append(Cut(start: operations[b].start, end: operations[b].end, text: ""))
                    merged.insert(b)
                    (shown, joined) = (false, true)
                } else if operations[b].operator == "q" || operations[b].operator == "Q" || construction.contains(operations[b].operator) || draws(operations, emptied, b) {
                    break
                }
                b += 1
            }
            if !joined { continue }
            let text = near(total, PdfMatrix.identity) ? ""
                : "\(PdfNumber(total.a).text) \(PdfNumber(total.b).text) \(PdfNumber(total.c).text) \(PdfNumber(total.d).text) \(PdfNumber(total.e).text) \(PdfNumber(total.f).text) cm"
            cuts.append(Cut(start: operations[a].start, end: operations[a].end, text: text))
        }
    }

    private static func draws(_ operations: [ContentOperation], _ emptied: Set<Int>, _ i: Int) -> Bool {
        let name = operations[i].operator
        return paints.contains(name) || name == "sh" || name == "Do" || name == "BI" || name == "'" || name == "\""
            || ((name == "Tj" || name == "TJ") && !emptied.contains(i))
    }

    private static func matrix(_ op: ContentOperation) -> PdfMatrix? {
        guard op.operator == "cm", op.operands.count == 6, op.operands.allSatisfy({ $0 is PdfNumber }),
              let a = op.number(0), let b = op.number(1), let c = op.number(2), let d = op.number(3), let e = op.number(4), let f = op.number(5) else { return nil }
        return PdfMatrix(a, b, c, d, e, f)
    }

    private static func near(_ a: PdfMatrix, _ b: PdfMatrix) -> Bool {
        abs(a.a - b.a) < 1e-9 && abs(a.b - b.b) < 1e-9 && abs(a.c - b.c) < 1e-9 && abs(a.d - b.d) < 1e-9 && abs(a.e - b.e) < 1e-6 && abs(a.f - b.f) < 1e-6
    }
}
