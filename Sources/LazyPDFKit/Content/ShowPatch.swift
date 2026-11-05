import Foundation

// Twin of windows/LazyPDF.Core/Content/ShowPatch.cs: cuts and insertions in one `Tj`, `TJ`, `'` or `"`, counted in
// bytes of the strings it shows. The result is one or more operators written over the original's byte range, so
// that a line that is still in one piece keeps the form it had.

/// One piece of what replaces a text-showing operator.
class ShowItem {}

/// Bytes to show with the font in force.
final class ShowText: ShowItem {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }
}

/// A number of a `TJ` array: thousandths of the font size to move back.
final class ShowShift: ShowItem {
    let amount: Double

    init(_ amount: Double) {
        self.amount = amount
    }
}

/// Operators written between the pieces of text, such as a font change.
final class ShowOps: ShowItem {
    let raw: [UInt8]

    init(_ raw: [UInt8]) {
        self.raw = raw
    }
}

final class ShowPatch {
    private var cuts: [(element: Int, start: Int, end: Int)] = []
    private var inserts: [(element: Int, offset: Int, items: [ShowItem])] = []

    let operation: ContentOperation

    init(_ operation: ContentOperation) {
        self.operation = operation
    }

    var count: (cuts: Int, inserts: Int) { (cuts.count, inserts.count) }

    func truncate(_ count: (cuts: Int, inserts: Int)) {
        cuts.removeLast(Swift.max(0, cuts.count - count.cuts))
        inserts.removeLast(Swift.max(0, inserts.count - count.inserts))
    }

    func cut(_ element: Int, _ start: Int, _ end: Int) {
        cuts.append((element, start, end))
    }

    func insert(_ element: Int, _ offset: Int, _ items: [ShowItem]) {
        inserts.append((element, offset, items))
    }

    func compile() -> Splice {
        var items: [ShowItem] = []
        let op = operation
        var elements: [PdfObject] = []
        let last = op.operands.last
        switch op.operator {
        case "Tj":
            if let last { elements.append(last) }
        case "'", "\"":
            let preamble = ContentWriter()
            let count = op.operands.count
            if op.operator == "\"" && count >= 3 {
                preamble.add(ContentOperation("Tw", [op.operands[count - 3]], 0, 0))
                preamble.add(ContentOperation("Tc", [op.operands[count - 2]], 0, 0))
            }
            preamble.op("T*")
            items.append(ShowOps(preamble.toArray()))
            if let last { elements.append(last) }
        default:
            if let array = last as? PdfArray { elements.append(contentsOf: array.items) }
        }
        // The element index of a quote operator's string is 0 or 1 in the interpreter; here the string is alone.
        let offsetOfElement = op.operator == "\"" ? 1 : 0
        for e in 0..<elements.count {
            let index = e + (elements.count == 1 ? offsetOfElement : 0)
            if let s = elements[e] as? PdfString {
                addString(&items, index, s.bytes)
            } else if let n = elements[e] as? PdfNumber {
                items.append(ShowShift(n.value))
            }
        }
        var hex = (last as? PdfString)?.isHex == true
        if let array = last as? PdfArray, let first = array.items.first as? PdfString, first.isHex { hex = true }
        return Splice(start: op.start, end: op.end, bytes: Self.write(items, hex))
    }

    private func addString(_ items: inout [ShowItem], _ element: Int, _ bytes: [UInt8]) {
        var run: [UInt8] = []
        func flush() {
            if !run.isEmpty { items.append(ShowText(run)) }
            run.removeAll()
        }
        for p in 0...bytes.count {
            for insert in inserts where insert.element == element && insert.offset == p {
                flush()
                items.append(contentsOf: insert.items)
            }
            if p == bytes.count { break }
            var isCut = false
            for c in cuts where c.element == element && p >= c.start && p < c.end { isCut = true }
            if !isCut { run.append(bytes[p]) }
        }
        flush()
    }

    /// Writes items as operators: consecutive text and shifts become one `Tj` or `TJ`.
    static func write(_ items: [ShowItem], _ hex: Bool) -> [UInt8] {
        let w = ContentWriter()
        var group: [ShowItem] = []
        func flush() {
            if group.isEmpty { return }
            if group.count == 1, let only = group[0] as? ShowText {
                w.op("Tj", [str(only.bytes, hex)])
            } else {
                let array: [PdfObject] = group.map { item in
                    if let t = item as? ShowText { return str(t.bytes, hex) }
                    return PdfNumber((item as? ShowShift)?.amount ?? 0)
                }
                w.op("TJ", [PdfArray(array)])
            }
            group.removeAll()
        }
        for item in items {
            if let ops = item as? ShowOps {
                flush()
                w.raw(Latin1.string(ops.raw))
            } else {
                group.append(item)
            }
        }
        flush()
        let bytes = w.toArray()
        // The original is followed by its own white space.
        return bytes.last == 10 ? Array(bytes.dropLast()) : bytes
    }

    static func str(_ bytes: [UInt8], _ hex: Bool) -> PdfString {
        let plain = !hex && bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return PdfString(bytes: bytes, isHex: !plain)
    }
}

/// Bytes `start` up to `end` of a content stream, replaced.
struct Splice {
    let start: Int
    let end: Int
    let bytes: [UInt8]
}
