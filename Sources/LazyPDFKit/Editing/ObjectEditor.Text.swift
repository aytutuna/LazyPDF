import Foundation

// Twin of windows/LazyPDF.Core/Editing/ObjectEditor.Text.cs: moving text with a matrix round it. A cm is not allowed
// inside a text object, so the object is left before the text and entered again after it, with the text matrices put
// back as they were. A run of glyphs may start or end in the middle of a string; the string is then cut in two there.

extension ObjectEditor {
    private static let painting: Set<String> =
        ["Tj", "TJ", "'", "\"", "Do", "BI", "sh", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*"]

    private static let positioning: Set<String> = ["Td", "TD", "Tm", "T*", "'", "\"", "BT", "ET"]

    static func isPainting(_ op: ContentOperation) -> Bool { painting.contains(op.operator) }

    private static func isPositioning(_ op: ContentOperation) -> Bool { positioning.contains(op.operator) }

    func transformText(_ block: TextObject, _ t: PdfMatrix) throws {
        for group in groupedByRun(block.glyphs.flatMap { [$0] + $0.twins }) {
            let place = Place(group.key.unit, group.key.visit)
            let glyphs = inStreamOrder(group.glyphs)
            let own = Set(glyphs)
            let ownOps = Set(glyphs.map { $0.op })
            var runs: [[EditGlyph]] = []
            for g in glyphs {
                if let previous = runs.last?.last, joins(place.unit, previous, g, own, ownOps) {
                    runs[runs.count - 1].append(g)
                } else {
                    runs.append([g])
                }
            }
            for run in runs { try transformRun(place, run, t) }
        }
    }

    // Two glyphs go in one wrap when nothing foreign is painted between them, the q levels balance between them,
    // and no cm changes the matrix in between.
    private func joins(_ unit: ContentUnit, _ a: EditGlyph, _ b: EditGlyph, _ own: Set<EditGlyph>, _ ownOps: Set<Int>) -> Bool {
        if a.op == b.op { return !model.foreignBetween(unit, a, b, own) }
        let ops = unit.operations
        var i = a.op + 1
        while i < b.op {
            if ops[i].operator == "cm" || (Self.isPainting(ops[i]) && !ownOps.contains(i)) { return false }
            i += 1
        }
        return Self.near(a.ctm, b.ctm) && TextEditor.balanced(unit, a.op, b.op) && !model.foreignBetween(unit, a, b, own)
    }

    private func transformRun(_ place: Place, _ run: [EditGlyph], _ t: PdfMatrix) throws {
        let unit = place.unit
        let ops = unit.operations
        guard let first = run.first, let last = run.last else { return }
        let around = try Self.around(first.ctm, t)
        guard let back = around.invert() else { throw EditConflictException(EditingText.tooBig) }
        let startsMid = model.glyphsAt(unit, first.op).first !== first
        let endsMid = model.glyphsAt(unit, last.op).last !== last
        // Mid-string the text matrix can only be set whole, so nothing may position text again until the run ends.
        if startsMid {
            var i = first.op + 1
            while i <= last.op {
                if Self.isPositioning(ops[i]) { throw EditConflictException(EditingText.notAlone) }
                i += 1
            }
        }

        var bt = -1
        var i = first.op - 1
        while !startsMid && i >= 0 {
            if ops[i].operator == "BT" {
                bt = i
                break
            }
            if ops[i].operator == "ET" || Self.isPainting(ops[i]) { break }
            i -= 1
        }
        var et = -1
        i = last.op + 1
        while !endsMid && i < ops.count {
            if ops[i].operator == "ET" {
                et = i
                break
            }
            if Self.isPainting(ops[i]) || ops[i].operator == "BT" { break }
            i += 1
        }
        let startIndex = bt >= 0 ? bt : first.op, endIndex = et >= 0 ? et : last.op
        if !TextEditor.balanced(unit, startIndex, endIndex) { throw EditConflictException(EditingText.unbalanced) }

        let forward = Self.matrix(around), reverse = Self.matrix(back)
        if bt >= 0 {
            try insert(place, ops[bt].start, forward)
        } else if startsMid {
            try insertInString(place, first, 0, "ET\n" + forward + "BT\n" + Self.matrix1(first.textMatrix, "Tm"))
        } else {
            try insert(place, ops[first.op].start, "ET\n" + forward + "BT\n" + Self.matrix1(try Self.startMatrix(first), "Tm"))
        }
        if et >= 0 {
            try insert(place, ops[et].end, "\n" + reverse)
        } else if endsMid {
            try insertInString(place, last, last.length, "\nET\n" + reverse + "BT\n" + (try Self.endState(last, false)))
        } else {
            try insert(place, ops[last.op].end, "\nET\n" + reverse + "BT\n" + (try Self.endState(last, true)))
        }
    }

    // Operators written inside a string, which splits the operation there.
    private func insertInString(_ place: Place, _ at: EditGlyph, _ after: Int, _ text: String) throws {
        guard let patch = batch.patch(place, at.op) else { throw EditConflictException(EditingText.sharedForm) }
        patch.insert(at.element, at.offset + after, [ShowOps(Self.bytes(text))])
    }

    private static func near(_ a: PdfMatrix, _ b: PdfMatrix) -> Bool {
        abs(a.a - b.a) + abs(a.b - b.b) + abs(a.c - b.c) + abs(a.d - b.d) + abs(a.e - b.e) + abs(a.f - b.f) < 1e-4
    }

    private static func matrix1(_ m: PdfMatrix, _ op: String) -> String {
        Latin1.string(ContentWriter().op(op, m.a, m.b, m.c, m.d, m.e, m.f).toArray())
    }

    // The line matrix a show operation starts from, which is also the text matrix there: a positioning operator sets both.
    private static func startMatrix(_ first: EditGlyph) throws -> PdfMatrix {
        let op = first.unit.operations[first.op]
        if op.operator == "'" || op.operator == "\"" { return PdfMatrix.translate(0, first.leading).multiply(first.textLineMatrix) }
        let shift = leadingShift(op, first)
        let before = PdfMatrix.translate(-shift, 0).multiply(first.textMatrix)
        if !near(before, first.textLineMatrix) { throw EditConflictException(EditingText.notAlone) }
        return first.textLineMatrix
    }

    // Text space distance the numbers of a TJ array in front of the first string move the text by.
    private static func leadingShift(_ op: ContentOperation, _ first: EditGlyph) -> Double {
        var shift = 0.0
        if op.operator == "TJ", let array = op.operands.last as? PdfArray {
            var i = 0
            while i < first.element && i < array.items.count {
                if let n = array.items[i] as? PdfNumber { shift += -n.value / 1000 * first.fontSize * first.scale }
                i += 1
            }
        }
        return shift
    }

    // Operators that leave the line matrix and the text matrix as the content had them after the last glyph.
    // Numbers after the glyph in its TJ array count when the operation ends there.
    private static func endState(_ last: EditGlyph, _ trailing: Bool) throws -> String {
        let op = last.unit.operations[last.op]
        var shift = last.advance
        if trailing, op.operator == "TJ", let array = op.operands.last as? PdfArray {
            var i = last.element + 1
            while i < array.items.count {
                if let n = array.items[i] as? PdfNumber { shift += -n.value / 1000 * last.fontSize * last.scale }
                i += 1
            }
        }
        let line = last.textLineMatrix
        let after = PdfMatrix.translate(shift, 0).multiply(last.textMatrix)
        let text = matrix1(line, "Tm")
        if near(after, line) { return text }
        // The text matrix sits along the line from the line matrix: a number in a TJ array moves it there.
        let dx = after.e - line.e, dy = after.f - line.f
        let square = line.a * line.a + line.b * line.b
        let along = square < 1e-12 ? 0 : (dx * line.a + dy * line.b) / square
        if !near(PdfMatrix.translate(along, 0).multiply(line), after) { throw EditConflictException(EditingText.notAlone) }
        let amount = -along * 1000 / (last.fontSize * last.scale)
        return text + Latin1.string(ContentWriter().op("TJ", [PdfArray([PdfNumber(amount)])]).toArray())
    }
}
