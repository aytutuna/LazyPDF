import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfDocument.Objects.cs: the object table, loaded on first use and cached,
// as in Lazy Scan's PdfReaderLite.cs, with the objects of the file remembered as read so that a save can tell
// which ones changed.

extension PdfDocument {
    private static let maxReferenceHops = 32
    private static let maxCachedObjectStreams = 256
    private static let maxCachedObjectStreamBytes = 128 << 20
    private static let maxObjectStreamSize = 64 << 20
    // Reading an object can need another (a stream's /Length, an object stream); a longer chain is a trap.
    private static let maxLoadDepth = 32
    private static let maxFlattenedNodes = 4096

    /// A loaded object, its generation, and the fingerprint of its text when it was read.
    final class Slot {
        var value: PdfObject
        let generation: Int
        let print: UInt64
        let isNew: Bool

        init(_ value: PdfObject, _ generation: Int, _ print: UInt64, isNew: Bool) {
            self.value = value
            self.generation = generation
            self.print = print
            self.isNew = isNew
        }
    }

    final class ObjectStream {
        let bytes: PdfArrayBytes
        let size: Int
        let offsets: [Int: Int]
        let numbers: [Int]

        init(_ bytes: PdfArrayBytes, _ size: Int, _ offsets: [Int: Int], _ numbers: [Int]) {
            self.bytes = bytes
            self.size = size
            self.offsets = offsets
            self.numbers = numbers
        }
    }

    /// Object `number` as the newest revision has it, strings decrypted; nil when it is free, not listed or
    /// cannot be read. The same instance comes back every time.
    public func get(_ number: Int) -> PdfObject? {
        if let slot = objects[number] { return slot.value }
        guard let entry = entries[number], entry.kind != .free, entry.kind != .new else { return nil }
        if loading.count >= Self.maxLoadDepth || !loading.insert(number).inserted { return nil }
        defer { loading.remove(number) }
        var value: PdfObject?
        var generation = entry.generation
        if entry.kind == .inUse {
            (value, generation) = readPlain(number, entry)
            if let plain = value, security != nil, number != encryptNumber { decryptStrings(plain, number, generation) }
        } else {
            value = readCompressed(number, entry)
        }
        // An object that cannot be read stays null, without being tried again.
        let loaded = value ?? PdfNull.instance
        objects[number] = Slot(loaded, generation, fingerprint(loaded), isNew: false)
        return loaded
    }

    /// What a value stands for: a reference followed to the object it names, however many hops (a loop gives
    /// up after 32). Nil for null, for a free or missing object.
    public func resolve(_ value: PdfObject?) -> PdfObject? {
        var value = value
        var hops = 0
        while let reference = value as? PdfReference {
            hops += 1
            if hops > Self.maxReferenceHops { return nil }
            value = get(reference.number)
        }
        return value is PdfNull ? nil : value
    }

    public func resolve<T: PdfObject>(_ value: PdfObject?, as type: T.Type) -> T? {
        resolve(value) as? T
    }

    public func dict(_ dictionary: PdfDictionary?, _ key: String) -> PdfDictionary? { resolve(dictionary?[key]) as? PdfDictionary }
    public func array(_ dictionary: PdfDictionary?, _ key: String) -> PdfArray? { resolve(dictionary?[key]) as? PdfArray }
    public func stream(_ dictionary: PdfDictionary?, _ key: String) -> PdfStream? { resolve(dictionary?[key]) as? PdfStream }
    public func name(_ dictionary: PdfDictionary?, _ key: String) -> String? { (resolve(dictionary?[key]) as? PdfName)?.value }
    public func bool(_ dictionary: PdfDictionary?, _ key: String) -> Bool? { (resolve(dictionary?[key]) as? PdfBoolean)?.value }
    public func number(_ dictionary: PdfDictionary?, _ key: String) -> Double? { (resolve(dictionary?[key]) as? PdfNumber)?.value }

    /// An integer; a real that is whole (90.0) counts too.
    public func integer(_ dictionary: PdfDictionary?, _ key: String) -> Int? {
        guard let number = resolve(dictionary?[key]) as? PdfNumber else { return nil }
        return number.integer ?? Self.wholeNumber(number.value)
    }

    private static func wholeNumber(_ value: Double) -> Int? {
        value.isFinite && abs(value) < Double(Int.max) && value == value.rounded(.down) ? Int(value) : nil
    }

    public func rect(_ dictionary: PdfDictionary?, _ key: String) -> PdfRect? { rect(dictionary?[key]) }

    /// A rectangle from an array of four numbers (corners in any order); nil for anything else or one with no area.
    public func rect(_ value: PdfObject?) -> PdfRect? {
        guard let array = resolve(value) as? PdfArray, array.items.count >= 4 else { return nil }
        var n: [Double] = []
        for item in array.items.prefix(4) {
            guard let number = resolve(item) as? PdfNumber, number.value.isFinite else { return nil }
            n.append(number.value)
        }
        let rect = PdfRect(n[0], n[1], n[2], n[3])
        return rect.isEmpty ? nil : rect
    }

    /// The generation of object `number`; 0 for one that is not listed.
    func generationOf(_ number: Int) -> Int {
        objects[number]?.generation ?? entries[number]?.generation ?? 0
    }

    /// Every object number the document lists as in use, ascending.
    public var objectNumbers: [Int] {
        entries.filter { $0.value.kind != .free }.map { $0.key }.sorted()
    }

    /// Makes `value` an indirect object under a new number and returns its reference. Throws when the file
    /// has used up PDF's object numbers, which a crafted /Size can do.
    public func add(_ value: PdfObject) throws -> PdfReference {
        if nextObjectNumber > Self.maxObjectNumber { throw PdfReadException.damaged("The file has no object numbers left.") }
        let number = nextObjectNumber
        nextObjectNumber += 1
        set(number, value)
        return PdfReference(number, 0)
    }

    /// Gives object `number` a new value; it is written at the next save whatever it holds.
    public func set(_ number: Int, _ value: PdfObject) {
        precondition(number >= 1 && number <= Self.maxObjectNumber, "number")
        let generation = generationOf(number)
        if let stream = value as? PdfStream {
            // File-backed data is read with the number it was stored under.
            if stream.data == nil { stream.data = rawData(stream) }
            stream.number = number
            stream.generation = generation
        }
        entries[number] = Entry(.new, 0, generation, 0)
        objects[number] = Slot(value, generation, 0, isNew: true)
        deleted.remove(number)
        if number >= nextObjectNumber { nextObjectNumber = number + 1 }
    }

    /// Frees object `number`; references to it then read as null.
    public func delete(_ number: Int) {
        guard let entry = entries[number], entry.kind != .free else { return }
        objects[number] = nil
        if number >= firstNew && entry.kind == .new {
            entries[number] = nil
            return
        }
        entries[number] = Entry(.free, 0, Swift.min(entry.generation + 1, 65535), 0)
        deleted.insert(number)
    }

    /// The numbers of the objects that are new or differ from what was read, ascending; freed ones are not
    /// among them. A loaded object is compared with the fingerprint of its text taken when it was read, a
    /// stream by its dictionary and by whether its `PdfStream.data` was set.
    func changedObjects() -> [Int] {
        var changed: [Int] = []
        for (number, slot) in objects {
            if slot.isNew || (slot.value as? PdfStream)?.data != nil || fingerprint(slot.value) != slot.print {
                changed.append(number)
            }
        }
        return changed.sorted()
    }

    /// The numbers freed since the file was read, ascending.
    var deletedObjects: [Int] { deleted.sorted() }

    /// The trailer holds something other than what was read.
    var trailerChanged: Bool { fingerprint(trailer) != trailerPrint }

    // FNV-1a over the text of the value as the writer puts it, plus its length.
    func fingerprint(_ value: PdfObject) -> UInt64 {
        var text = ""
        ((value as? PdfStream)?.dictionary ?? value).writeTo(&text)
        var hash: UInt64 = 14695981039346656037
        var length: UInt64 = 0
        for unit in text.utf16 {
            hash = (hash ^ UInt64(unit)) &* 1099511628211
            length += 1
        }
        return hash &+ length
    }

    private func readPlain(_ number: Int, _ entry: Entry) -> (value: PdfObject?, generation: Int) {
        if let parsed = tryParseAt(entry.offset, number) { return parsed }
        let found = ensureScan().objects[number]
        if let found, found.offset != entry.offset, let parsed = tryParseAt(found.offset, number) {
            addRepair("Object \(number) was listed at byte \(entry.offset); found at byte \(found.offset).")
            var moved = entry
            moved.offset = found.offset
            entries[number] = moved
            return parsed
        }
        addRepair("Object \(number) could not be read.")
        return (nil, 0)
    }

    /// The object at `offset` if its header is for `number` (any number when it is 0) and it parses.
    private func tryParseAt(_ offset: Int, _ number: Int) -> (value: PdfObject?, generation: Int)? {
        if offset < 0 || offset >= source.count { return nil }
        do {
            let lexer = PdfLexer(sourceBytes, position: offset)
            let (found, gen) = try lexer.readObjectHeader()
            if number != 0 && found != number { return nil }
            let value = try lexer.readObject()
            if let stream = value as? PdfStream {
                stream.number = found
                stream.generation = gen
            }
            return (value, gen)
        } catch {
            return nil
        }
    }

    private func readCompressed(_ number: Int, _ entry: Entry) -> PdfObject? {
        if let members = loadObjectStream(entry.streamNumber), let at = members.offsets[number] {
            do {
                return try PdfLexer(members.bytes, position: at).readObject(allowStream: false)
            } catch {
                addRepair("Object \(number) in object stream \(entry.streamNumber) could not be read.")
                return nil
            }
        }
        addRepair("Object \(number) is not in object stream \(entry.streamNumber).")
        return nil
    }

    func loadObjectStream(_ number: Int) -> ObjectStream? {
        if let cached = objectStreams[number] { return cached }
        guard let stream = get(number) as? PdfStream, name(stream.dictionary, "Type") == "ObjStm" else { return nil }
        guard let n = integer(stream.dictionary, "N"), n >= 0, let first = integer(stream.dictionary, "First"), first >= 0 else { return nil }
        let data: [UInt8]
        do {
            data = try self.data(stream, Self.maxObjectStreamSize)
        } catch {
            addRepair("Object stream \(number) could not be read (\(error)).")
            return nil
        }
        let bytes = PdfArrayBytes(data)
        let header = PdfLexer(bytes)
        var offsets: [Int: Int] = [:]
        var numbers: [Int] = []
        var i = 0
        while i < n {
            guard let objectNumber = header.tryReadUnsigned(), let relative = header.tryReadUnsigned() else {
                addRepair("Object stream \(number)'s header lists \(i) objects, not the \(n) it says.")
                break
            }
            i += 1
            let (start, overflow) = first.addingReportingOverflow(relative)
            if objectNumber < 1 || objectNumber > Self.maxObjectNumber || overflow || start >= data.count { continue }
            if offsets[objectNumber] == nil { offsets[objectNumber] = start }
            numbers.append(objectNumber)
        }
        let cachedBytes = objectStreams.values.reduce(0) { $0 + $1.size }
        if objectStreams.count >= Self.maxCachedObjectStreams || cachedBytes + data.count > Self.maxCachedObjectStreamBytes {
            objectStreams.removeAll()
        }
        let loaded = ObjectStream(bytes, data.count, offsets, numbers)
        objectStreams[number] = loaded
        return loaded
    }

    /// Resolves the references in a value down to `depth` levels, as the filters and the security handler want
    /// their parameters. Streams are left as they are, or read as nothing when `streams` is false (a value that is
    /// written back as a direct one). Shared references would multiply at every level, so after a few thousand
    /// values the rest reads as nothing.
    func flatten(_ value: PdfObject?, _ depth: Int, streams: Bool = true) -> PdfObject? {
        var budget = Self.maxFlattenedNodes
        return flatten(value, depth, streams, &budget)
    }

    private func flatten(_ value: PdfObject?, _ depth: Int, _ streams: Bool, _ budget: inout Int) -> PdfObject? {
        let resolved = resolve(value)
        if !streams && resolved is PdfStream { return nil }
        if depth > 0, let array = resolved as? PdfArray {
            var items: [PdfObject] = []
            for item in array.items {
                budget -= 1
                if budget < 0 { break }
                items.append(flatten(item, depth - 1, streams, &budget) ?? PdfNull.instance)
            }
            return PdfArray(items)
        }
        if depth > 0, let dictionary = resolved as? PdfDictionary {
            let copy = PdfDictionary()
            for (key, item) in dictionary.entries {
                budget -= 1
                if budget < 0 { break }
                copy.add(key, flatten(item, depth - 1, streams, &budget) ?? PdfNull.instance)
            }
            return copy
        }
        return resolved
    }
}
