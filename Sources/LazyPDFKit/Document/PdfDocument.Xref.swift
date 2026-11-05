import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Xref.cs: cross-reference sections as in Lazy Scan's
// PdfReaderLite.cs, classic tables, cross-reference streams (ISO 32000-1 7.5.8), /Prev chains and the /XRefStm
// of hybrid files (7.5.8.4).

extension PdfDocument {
    /// Longest /Prev chain followed (a loop is caught before that).
    static let maxSections = 4096

    enum EntryKind { case free, inUse, compressed, new }

    /// One cross-reference entry: in use at an offset, in an object stream, free, or made since the file was read.
    struct Entry {
        var kind: EntryKind
        var offset: Int
        var generation: Int
        var streamNumber: Int

        init(_ kind: EntryKind, _ offset: Int, _ generation: Int, _ streamNumber: Int) {
            self.kind = kind
            self.offset = offset
            self.generation = generation
            self.streamNumber = streamNumber
        }
    }

    static let trailerKeys = ["Root", "Info", "ID", "Encrypt"]
    static let xrefStreamKeys = ["Type", "W", "Index", "Length", "Filter", "DecodeParms", "Prev", "XRefStm"]

    func loadCrossReferences() throws {
        let start = try findStartXref()
        var visited = Set<Int>()
        var found: [Int] = []
        var newest: PdfDictionary?
        var highest = 0
        var offset: Int? = start
        loadingXref = true
        defer { loadingXref = false }
        while let at = offset {
            if !visited.insert(at).inserted {
                throw PdfReadException.damaged("The cross-reference sections point back at each other (/Prev).")
            }
            if visited.count > Self.maxSections { throw PdfReadException.damaged("Too many cross-reference sections.") }
            found.append(at)
            let (dictionary, isStream, sectionHighest) = try readSection(at)
            highest = max(highest, sectionHighest)
            if let current = newest {
                for key in Self.trailerKeys where !current.containsKey(key) {
                    if let value = dictionary[key] { current[key] = value }
                }
            } else {
                xrefIsStream = isStream
                newest = dictionary.copy()
            }
            if let size = (dictionary["Size"] as? PdfNumber)?.integer, size >= 1, size <= Self.maxObjectNumber + 1 {
                highest = max(highest, size - 1)
            }
            switch dictionary["Prev"] {
            case nil:
                offset = nil
            case let prev as PdfNumber where prev.value > 0 && prev.value < Double(source.count):
                offset = Int(prev.value)
            default:
                throw PdfReadException.damaged("/Prev does not point into the file.")
            }
        }
        guard let result = newest else { throw PdfReadException.damaged("There is no trailer.") }
        for key in Self.xrefStreamKeys { result.remove(key) }
        trailer = result
        startXref = start
        sections = found
        nextObjectNumber = highest + 1
    }

    private func findStartXref() throws -> Int {
        let keyword = "startxref".keywordBytes
        guard let at = source.lastIndexOf(keyword) else { throw PdfReadException.damaged("There is no startxref.") }
        guard let offset = PdfLexer(sourceBytes, position: at + keyword.count).tryReadUnsigned(),
              offset > 0, offset < source.count else {
            throw PdfReadException.damaged("startxref does not point into the file.")
        }
        return offset
    }

    /// One section at `offset`: its entries (newer ones already read win), its trailer dictionary.
    private func readSection(_ offset: Int) throws -> (trailer: PdfDictionary, isStream: Bool, highest: Int) {
        let lexer = PdfLexer(sourceBytes, position: offset)
        lexer.skipWhiteSpace()
        let start = lexer.position
        if lexer.readKeyword() == "xref" {
            var section: [Int: Entry] = [:]
            var highest: Int
            (lexer.position, highest) = try readTable(lexer.position, &section)
            if lexer.readKeyword() != "trailer" { throw PdfReadException.damaged("A cross-reference table has no trailer.") }
            guard let trailer = try lexer.readObject(allowStream: false) as? PdfDictionary else {
                throw PdfReadException.damaged("The trailer is not a dictionary.")
            }
            // A hybrid file: the classic table's objects, then the ones only its stream lists
            // (the table gives those as free, or not at all).
            if let streamOffset = trailer["XRefStm"] {
                // Sections that name the same stream would decode it again for nothing: the newest named it first.
                guard let so = (streamOffset as? PdfNumber)?.integer, so > 0, so < source.count else {
                    throw PdfReadException.damaged("/XRefStm does not point into the file.")
                }
                if hybridStreams.insert(so).inserted {
                    var streamSection: [Int: Entry] = [:]
                    let (_, streamHighest) = try readStreamSection(so, &streamSection)
                    highest = max(highest, streamHighest)
                    for (number, entry) in streamSection {
                        if let listed = section[number], listed.kind != .free { continue }
                        section[number] = entry
                    }
                }
            }
            merge(section)
            return (trailer, false, highest)
        }
        var entries: [Int: Entry] = [:]
        let (dictionary, h) = try readStreamSection(start, &entries)
        merge(entries)
        return (dictionary, true, h)
    }

    /// Entries of an older section count only where no newer one has spoken.
    private func merge(_ section: [Int: Entry]) {
        for (number, entry) in section where entries[number] == nil { entries[number] = entry }
    }

    /// A classic table's subsections ("first count", then count lines of "offset generation n|f"); the position
    /// after the last one. An offset past the file is kept: the object is looked for when it is wanted.
    private func readTable(_ start: Int, _ section: inout [Int: Entry]) throws -> (position: Int, highest: Int) {
        var pos = start
        var highest = 0
        while true {
            let save = pos
            guard var first = readUnsigned(&pos) else { return (save, highest) }
            guard let count = readUnsigned(&pos) else {
                throw PdfReadException.damaged("A cross-reference subsection header is not two numbers.")
            }
            if first + count > Self.maxObjectNumber + 1 {
                throw PdfReadException.damaged("A cross-reference subsection goes past PDF's highest object number (\(Self.maxObjectNumber)).")
            }
            var i = 0
            while i < count {
                guard let entryOffset = readUnsigned(&pos), let generation = readUnsigned(&pos) else {
                    throw PdfReadException.damaged("Cross-reference entry \(first + i) is not \"offset generation n|f\".")
                }
                while pos < source.count && PdfLexer.isWhiteSpace(Int(source[pos])) { pos += 1 }
                var kind: UInt8 = 0
                if pos < source.count {
                    kind = source[pos]
                    pos += 1
                }
                if (kind != UInt8(ascii: "n") && kind != UInt8(ascii: "f")) || generation > 65535 {
                    throw PdfReadException.damaged("Cross-reference entry \(first + i) is not \"offset generation n|f\".")
                }
                // A table that starts at 1 but opens with the free-list head was meant to start at 0.
                if i == 0 && first == 1 && kind == UInt8(ascii: "f") && generation == 65535 { first = 0 }
                let number = first + i
                i += 1
                if number == 0 { continue }
                let inUse = kind == UInt8(ascii: "n") && entryOffset > 0
                if section[number] == nil {
                    section[number] = inUse ? Entry(.inUse, entryOffset, generation, 0) : Entry(.free, 0, generation, 0)
                }
                if inUse { highest = max(highest, number) }
            }
        }
    }

    /// Digits after white space; nil (and `pos` unchanged) when there are none or too many.
    private func readUnsigned(_ pos: inout Int) -> Int? {
        var value = 0
        var p = pos
        while p < source.count && PdfLexer.isWhiteSpace(Int(source[p])) { p += 1 }
        var digits = 0
        while p < source.count && source[p] >= 0x30 && source[p] <= 0x39 {
            digits += 1
            if digits > 18 { return nil }
            value = value * 10 + Int(source[p] - 0x30)
            p += 1
        }
        if digits == 0 { return nil }
        pos = p
        return value
    }

    /// A cross-reference stream (/Type /XRef) at `offset`: its entries and its dictionary.
    private func readStreamSection(_ offset: Int, _ section: inout [Int: Entry]) throws -> (dictionary: PdfDictionary, highest: Int) {
        let lexer = PdfLexer(sourceBytes, position: offset)
        let (number, generation) = try lexer.readObjectHeader()
        guard let stream = try lexer.readObject() as? PdfStream, (stream.dictionary["Type"] as? PdfName)?.value == "XRef" else {
            throw PdfReadException.damaged("startxref points at neither a cross-reference table nor a cross-reference stream.")
        }
        stream.number = number
        stream.generation = generation
        let dictionary = stream.dictionary
        // A cross-reference stream's own entries are direct: nothing can be looked up yet.
        guard let w = dictionary["W"] as? PdfArray, w.items.count == 3,
              w.items.allSatisfy({ (($0 as? PdfNumber)?.integer).map { $0 >= 0 && $0 <= 8 } ?? false }) else {
            throw PdfReadException.damaged("A cross-reference stream's /W is not three field widths.")
        }
        let widths = w.items.map { ($0 as? PdfNumber)?.integer ?? 0 }
        guard let size = (dictionary["Size"] as? PdfNumber)?.integer, size >= 0 else {
            throw PdfReadException.damaged("A cross-reference stream has no /Size.")
        }
        var index = [0, size]
        if let indexArray = dictionary["Index"] as? PdfArray {
            index = []
            for item in indexArray.items {
                guard let n = (item as? PdfNumber)?.integer, n >= 0, n <= Self.maxObjectNumber + 1 else {
                    throw PdfReadException.damaged("A cross-reference stream's /Index is not numbers.")
                }
                index.append(n)
            }
        }
        if index.count % 2 != 0 { throw PdfReadException.damaged("A cross-reference stream's /Index has an odd count.") }
        let bytes = try self.data(stream)
        let entryLength = widths.reduce(0, +)
        if entryLength == 0 { throw PdfReadException.damaged("A cross-reference stream's entries are empty.") }
        var highest = 0
        var at = 0
        for k in stride(from: 0, to: index.count, by: 2) {
            let first = index[k], count = index[k + 1]
            if first + count > Self.maxObjectNumber + 1 {
                throw PdfReadException.damaged("A cross-reference stream's /Index goes past PDF's highest object number (\(Self.maxObjectNumber)).")
            }
            var i = 0
            while i < count {
                if at + entryLength > bytes.count {
                    throw PdfReadException.damaged("A cross-reference stream is shorter than its /Index says.")
                }
                // A missing first field means type 1.
                let type = widths[0] == 0 ? 1 : Self.field(bytes, at, widths[0])
                let second = Self.field(bytes, at + widths[0], widths[1])
                let third = Self.field(bytes, at + widths[0] + widths[1], widths[2])
                at += entryLength
                let objectNumber = first + i
                i += 1
                if objectNumber == 0 { continue }
                let entry: Entry
                if type == 0 {
                    entry = Entry(.free, 0, Self.generationField(third), 0)
                } else if type == 1 && second > 0 {
                    entry = Entry(.inUse, second, Self.generationField(third), 0)
                    highest = max(highest, objectNumber)
                } else if type == 2 && second > 0 && second <= Int(Int32.max) {
                    entry = Entry(.compressed, 0, 0, second)
                    highest = max(highest, objectNumber)
                } else {
                    // Types a later PDF version may add read as null (7.5.8.3), and so hide the entry of an older section.
                    entry = Entry(.free, 0, 0, 0)
                }
                if section[objectNumber] == nil { section[objectNumber] = entry }
            }
        }
        return (dictionary, highest)
    }

    private static func field(_ data: [UInt8], _ at: Int, _ width: Int) -> Int {
        var value = 0
        for i in 0..<width { value = (value << 8) | Int(data[at + i]) }
        return value
    }

    /// The C# takes the lower of the field and 65535 and casts it to int, which wraps for a negative field.
    private static func generationField(_ third: Int) -> Int {
        Int(Int32(truncatingIfNeeded: Swift.min(third, 65535)))
    }
}
