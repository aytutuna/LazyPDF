import Foundation

// Twin of windows/LazyPDF.Core/Signatures/StrictSections.cs: the cross-reference parts of an update, read by
// StrictReader: a table with its trailer or a stream, "startxref" and "%%EOF" (ISO 32000-1 7.5.4 to 7.5.8), and the
// members of an object stream.

extension UpdateGate {
    // Type 0 is free, 1 in use at second with generation third, 2 the member third of object stream second.
    struct Listed {
        var number: Int
        var type: Int
        var second: Int
        var third: Int
    }

    struct Section {
        var start: Int
        var trailer: [String: Slice]
        var entries: [Listed]
        var objects: [StrictReader.Indirect]
        var streamNumber: Int
    }

    static let trailerKeys = ["Size", "Prev", "Root", "Info", "Encrypt", "ID"]
    static let streamKeys = ["Type", "W", "Index", "Filter", "DecodeParms", "Length"]

    // The objects of an update up to its cross-reference section, which is read whole, "%%EOF" included.
    func readSection(_ reader: StrictReader, update: Bool) -> Section? {
        var objects: [StrictReader.Indirect] = []
        while true {
            reader.skipSpace()
            let at = reader.pos
            if reader.word("xref") { return readTable(reader, at, objects) }
            guard let o = reader.object() else { return nil }
            objects.append(o)
            if o.isStream, let type = o.keys?["Type"], reader.nameOf(type) == "XRef" { return readStream(reader, o, objects, update) }
        }
    }

    private func readTable(_ reader: StrictReader, _ start: Int, _ objects: [StrictReader.Indirect]) -> Section? {
        var entries: [Listed] = []
        reader.skipSpace()
        while !reader.word("trailer") {
            guard let first = reader.unsigned() else { return nil }
            reader.skipSpace()
            guard let count = reader.unsigned(), first + count <= PdfDocument.maxObjectNumber + 1, count * 20 <= data.count - reader.pos else { return nil }
            reader.skipSpace()
            for i in 0..<count {
                guard let entry = tableEntry(reader.pos, first + i) else { return nil }
                reader.pos += 20
                if entry.number > 0 { entries.append(entry) }
            }
            reader.skipSpace()
        }
        let trailer = StrictReader.KeySpans()
        let read = reader.value(depth: 0, keys: trailer)
        if !read.ok || read.slice.start + 1 >= data.count || data[read.slice.start] != UInt8(ascii: "<") || data[read.slice.start + 1] != UInt8(ascii: "<") { return nil }
        return Self.tail(reader, start, trailer.map, entries, objects, 0)
    }

    // Twenty bytes: ten digits, a space, five digits, a space, n or f, and a two-byte line end (7.5.4).
    private func tableEntry(_ at: Int, _ number: Int) -> Listed? {
        if at + 20 > data.count || data[at + 10] != UInt8(ascii: " ") || data[at + 16] != UInt8(ascii: " ") { return nil }
        guard let offset = digits(at, 10), let generation = digits(at + 11, 5) else { return nil }
        let end = (data[at + 18], data[at + 19])
        let lineEnd = end == (32, 10) || end == (32, 13) || end == (13, 10)
        if !lineEnd || generation > 65535 { return nil }
        switch data[at + 17] {
        case UInt8(ascii: "n") where number > 0 && offset > 0 && offset < Int(Int32.max): return Listed(number: number, type: 1, second: offset, third: generation)
        case UInt8(ascii: "f"): return Listed(number: number, type: 0, second: offset, third: generation)
        default: return nil
        }
    }

    private func digits(_ at: Int, _ count: Int) -> Int? {
        var value = 0
        for i in 0..<count {
            let c = data[at + i]
            if c < UInt8(ascii: "0") || c > UInt8(ascii: "9") { return nil }
            value = value * 10 + Int(c - UInt8(ascii: "0"))
        }
        return value
    }

    private func readStream(_ reader: StrictReader, _ o: StrictReader.Indirect, _ objects: [StrictReader.Indirect], _ update: Bool) -> Section? {
        var entries: [Listed] = []
        if update && !streamEntries(reader, o, &entries) { return nil }
        return Self.tail(reader, o.start, o.keys ?? [:], entries, objects, o.number)
    }

    // "startxref", the offset of this section and "%%EOF".
    private static func tail(_ reader: StrictReader, _ start: Int, _ trailer: [String: Slice], _ entries: [Listed],
                             _ objects: [StrictReader.Indirect], _ streamNumber: Int) -> Section? {
        reader.skipSpace()
        if !reader.word("startxref") { return nil }
        reader.skipSpace()
        guard let at = reader.unsigned(), at == start else { return nil }
        reader.skipSpace()
        return reader.word("%%EOF") ? Section(start: start, trailer: trailer, entries: entries, objects: objects, streamNumber: streamNumber) : nil
    }

    // The rows of a cross-reference stream: /W three widths up to 8 bytes, /Index pairs (else 0 to /Size), and nothing left over (7.5.8.2).
    private func streamEntries(_ reader: StrictReader, _ o: StrictReader.Indirect, _ entries: inout [Listed]) -> Bool {
        guard let keys = o.keys, let size = keys["Size"], let count = reader.integer(size),
              let w = keys["W"], let widths = reader.integers(w), widths.count == 3, !widths.contains(where: { $0 > 8 }), widths.reduce(0, +) != 0 else { return false }
        var ranges = [0, count]
        if let index = keys["Index"] {
            guard let listed = reader.integers(index), listed.count % 2 == 0 else { return false }
            ranges = listed
        }
        var rows = 0
        for k in stride(from: 0, to: ranges.count, by: 2) {
            if ranges[k] + ranges[k + 1] > PdfDocument.maxObjectNumber + 1 { return false }
            rows += ranges[k + 1]
        }
        let width = widths.reduce(0, +)
        guard let decoded = decoded(o.start), decoded.count == rows * width else { return false }
        var at = 0
        for k in stride(from: 0, to: ranges.count, by: 2) {
            for i in 0..<ranges[k + 1] {
                let type = widths[0] == 0 ? 1 : Self.field(decoded, at, widths[0])
                let second = Self.field(decoded, at + widths[0], widths[1]), third = Self.field(decoded, at + widths[0] + widths[1], widths[2])
                let number = ranges[k] + i
                if number > PdfDocument.maxObjectNumber || type < 0 || type > 2 || second < 0 || third < 0 { return false }
                if number == 0 && type != 0 { return false }
                if type == 1 && (second == 0 || second >= Int(Int32.max)) { return false }
                if type == 2 && (second == 0 || second > PdfDocument.maxObjectNumber) { return false }
                if number > 0 { entries.append(Listed(number: number, type: type, second: second, third: third)) }
                at += width
            }
        }
        return true
    }

    // Up to 8 bytes: a field of 8 can wrap to a negative number, which the caller refuses.
    private static func field(_ data: [UInt8], _ at: Int, _ width: Int) -> Int {
        var value = 0
        for i in 0..<width { value = value << 8 | Int(data[at + i]) }
        return value
    }

    // The stream at offset, decoded the way the document decodes it (decrypted, filters applied); nil when it cannot be.
    func decoded(_ offset: Int) -> [UInt8]? {
        do {
            let lexer = PdfLexer(PdfArrayBytes(data), position: offset)
            let (number, generation) = try lexer.readObjectHeader()
            guard let stream = try lexer.readObject() as? PdfStream else { return nil }
            stream.number = number
            stream.generation = generation
            return try b.data(stream)
        } catch {
            return nil
        }
    }

    // The members of an object stream's data: /N pairs of number and offset, then each member's bytes to the next one's
    // start, the first at /First and the last to the end, so that every byte belongs to one member (7.5.7).
    static func members(_ data: [UInt8], _ count: Int, _ first: Int) -> [(number: Int, start: Int, end: Int)]? {
        if count < 0 || first < 0 || first > data.count || count > first { return nil }
        let header = StrictReader(data, first)
        var starts: [(number: Int, offset: Int)] = []
        for _ in 0..<count {
            header.skipSpace()
            guard let number = header.unsigned(), number >= 1, number <= PdfDocument.maxObjectNumber else { return nil }
            header.skipSpace()
            guard let offset = header.unsigned(), first + offset < data.count else { return nil }
            starts.append((number, first + offset))
        }
        header.skipSpace()
        if header.pos != first || starts.isEmpty || starts[0].offset != first || Set(starts.map { $0.number }).count != starts.count { return nil }
        var members: [(number: Int, start: Int, end: Int)] = []
        for k in 0..<starts.count {
            let next = k + 1 < starts.count ? starts[k + 1].offset : data.count
            if next <= starts[k].offset { return nil }
            let reader = StrictReader(data, next)
            reader.pos = starts[k].offset
            if !reader.value().ok { return nil }
            reader.skipSpace()
            if !reader.atEnd { return nil }
            members.append((starts[k].number, starts[k].offset, next))
        }
        return members
    }
}
