import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfXrefWriter.cs, after Lazy Scan's PdfObjectWriter.cs (Finish,
// FinishUpdate, FinishUpdateStream): the cross-reference section that closes a file or an update, as a table
// (ISO 32000-1 7.5.4) or a stream (7.5.8).

/// One cross-reference entry. Type 0 is free (`second` the next free number), type 1 in use (the offset), type 2
/// stored in an object stream (the stream's number, with `third` the index in it); for types 0 and 1 `third` is
/// the generation.
struct XrefEntry {
    let number: Int
    let type: Int
    let second: Int
    let third: Int

    init(_ number: Int, _ type: Int, _ second: Int, _ third: Int) {
        self.number = number
        self.type = type
        self.second = second
        self.third = third
    }
}

enum PdfXrefWriter {
    /// A classic table of `entries` (ascending, no type 2), a subsection to each run of consecutive numbers,
    /// then the trailer, "startxref" and "%%EOF".
    static func writeTable(_ writer: PdfObjectWriter, _ entries: [XrefEntry], _ trailer: PdfDictionary) {
        let start = writer.position
        var table = "xref\n"
        for (first, count) in runs(entries) {
            table.append("\(entries[first].number) \(count)\n")
            for i in first..<first + count {
                let entry = entries[i]
                table.append(padded(entry.second, 10))
                table.append(" ")
                table.append(padded(entry.third, 5))
                table.append(entry.type == 0 ? " f \n" : " n \n")
            }
        }
        table.append("trailer\n")
        writer.writeAscii(table)
        writer.writeDirect(trailer)
        writer.writeAscii("\nstartxref\n\(start)\n%%EOF\n")
    }

    /// A cross-reference stream, object `number`, written last and listing itself. /W is [1 w 2] with w wide
    /// enough for the largest offset. `dictionary` holds /Size, /Root and the rest of what a trailer holds.
    static func writeStream(_ writer: PdfObjectWriter, _ number: Int, _ entries: [XrefEntry], _ dictionary: PdfDictionary, compress: Bool) {
        let start = writer.position
        var entries = entries
        entries.append(XrefEntry(number, 1, start, 0))
        var width = 1
        for entry in entries {
            while width < 8 && entry.second >= 1 << (width * 8) { width += 1 }
        }
        var data: [UInt8] = []
        data.reserveCapacity(entries.count * (width + 3))
        for entry in entries {
            data.append(UInt8(truncatingIfNeeded: entry.type))
            for b in stride(from: width - 1, through: 0, by: -1) { data.append(UInt8(truncatingIfNeeded: entry.second >> (b * 8))) }
            data.append(UInt8(truncatingIfNeeded: entry.third >> 8))
            data.append(UInt8(truncatingIfNeeded: entry.third))
        }

        var index: [PdfObject] = []
        for (first, count) in runs(entries) {
            index.append(PdfNumber(entries[first].number))
            index.append(PdfNumber(count))
        }
        let head = PdfDictionary()
        head.add("Type", PdfName("XRef"))
        head.add("W", PdfArray([PdfNumber(1), PdfNumber(width), PdfNumber(2)]))
        head.add("Index", PdfArray(index))
        for (key, value) in dictionary.entries { head.add(key, value) }
        if compress {
            data = PdfFilterEncoders.flate(data)
            head.add("Filter", PdfName("FlateDecode"))
        }
        writer.writeStream(number, 0, head, data, encrypt: false)
        writer.writeAscii("startxref\n\(start)\n%%EOF\n")
    }

    /// The trailer's /ID: the file's first string and a fresh second one.
    static func idPair(_ first: [UInt8]) -> PdfArray {
        PdfArray([PdfString(bytes: first, isHex: true), PdfString(bytes: PdfSecurity.systemRandom(16), isHex: true)])
    }

    /// The runs of consecutive numbers in `entries` (ascending): where each starts in the list and how long it is.
    private static func runs(_ entries: [XrefEntry]) -> [(first: Int, count: Int)] {
        var runs: [(Int, Int)] = []
        var i = 0
        while i < entries.count {
            var j = i + 1
            while j < entries.count && entries[j].number == entries[j - 1].number + 1 { j += 1 }
            runs.append((i, j - i))
            i = j
        }
        return runs
    }

    /// Digits with leading zeros to at least `width`, a minus sign in front of a negative number (ToString("D10")).
    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value.magnitude)
        return (value < 0 ? "-" : "") + String(repeating: "0", count: Swift.max(0, width - digits.count)) + digits
    }
}
