import Foundation

// Twin of windows/LazyPDF.Core/Signatures/UpdateGate.cs: decides whether everything after the signed bytes is
// something the checker can account for. The bytes are read by StrictReader alone, update by update: objects, a
// cross-reference section that lists each of them once and points exactly at it, "startxref", "%%EOF". Anything
// else, and any trailer that moves the catalog, is not judged further; the caller treats the file as changed. The
// tolerant reader is used only for what the strict one has already passed.

final class UpdateGate {
    private static let maxSections = 256

    let a: PdfDocument
    let b: PdfDocument
    let data: [UInt8]
    var finals: [Int: Listed] = [:]
    var touched = Set<Int>()
    var defined = Set<Int>()
    var plumbing = Set<Int>()
    var signedStreams: [Int: Bool] = [:]
    private var info = 0

    private init(_ signed: PdfDocument, _ later: PdfDocument, _ data: [UInt8]) {
        a = signed
        b = later
        self.data = data
    }

    /// What the updates list: every number they list, and those they give an object to at some point, even one a later
    /// update frees. `plumbing` are the cross-reference streams and object streams they write.
    struct Listing {
        var touched: Set<Int>
        var defined: Set<Int>
        var plumbing: Set<Int>
    }

    /// What the updates after `signed` list, or nil when they cannot all be placed exactly.
    /// `signed` must be the first part of `later`, cut at the end of the signed bytes.
    static func check(_ signed: PdfDocument, _ later: PdfDocument) -> Listing? {
        let data = later.source
        if signed.source.count > data.count || signed.xrefRebuilt || later.xrefRebuilt || !data.starts(with: signed.source) { return nil }
        let gate = UpdateGate(signed, later, data)
        return gate.run() ? Listing(touched: gate.touched, defined: gate.defined, plumbing: gate.plumbing) : nil
    }

    private func run() -> Bool {
        guard let tail = readSignedTail() else { return false }
        let reader = StrictReader(data, data.count)
        reader.pos = a.source.count
        var last: Section?
        var end = a.source.count
        var size = tail.size
        var previous = a.startXref
        var count = 0
        while true {
            reader.skipSpace()
            if reader.atEnd { break }
            guard count < Self.maxSections, let section = readSection(reader, update: true), verify(section, tail, previous, &size) else { return false }
            last = section
            end = reader.pos
            previous = section.start
            count += 1
        }
        // A single line end may follow the last "%%EOF" (7.5.5).
        let rest = Array(data[end...])
        guard let last, rest.isEmpty || rest == [10] || rest == [13] || rest == [13, 10] else { return false }
        return b.startXref == last.start && tables() && replaced()
    }

    private struct SignedTail {
        var section: Section
        var size: Int
    }

    // The section the signed revision ends with, read from where its startxref says: it has to run to the end of the
    // signed bytes, or a comment or an open object there could hide what the update then writes.
    private func readSignedTail() -> SignedTail? {
        let at = a.startXref
        if at <= 0 || at >= a.source.count { return nil }
        let reader = StrictReader(data, a.source.count)
        reader.pos = at
        guard let section = readSection(reader, update: false), section.start == at else { return nil }
        var i = reader.pos
        while i < a.source.count {
            if !StrictReader.isSpace(data[i]) { return nil }
            i += 1
        }
        guard let root = section.trailer["Root"], data[root.start] >= UInt8(ascii: "0"), data[root.start] <= UInt8(ascii: "9"),
              data[root.end - 1] == UInt8(ascii: "R") else { return nil }
        guard let size = section.trailer["Size"], let value = StrictReader(data, data.count).integer(size) else { return nil }
        return SignedTail(section: section, size: value)
    }

    private func verify(_ section: Section, _ signed: SignedTail, _ previous: Int, _ size: inout Int) -> Bool {
        let reader = StrictReader(data, data.count)
        let trailer = section.trailer
        guard let prev = trailer["Prev"], let at = reader.integer(prev), at == previous else { return false }
        guard let sizeSlice = trailer["Size"], let newSize = reader.integer(sizeSlice) else { return false }
        // The catalog and encryption are the signed revision's own, in the same bytes. Information may be added where there was
        // none, but as an object of this update, which the rules then judge: a direct dictionary or an old object touches nothing.
        for key in ["Root", "Info", "Encrypt"] {
            let was = signed.section.trailer[key], now = trailer[key]
            if key == "Info" && was == nil, let now {
                if !newInfo(reader, now, section) { return false }
                continue
            }
            if (was == nil) != (now == nil) { return false }
            if let was, let now, !reader.same(was, now) { return false }
        }
        if !sameId(reader, signed.section.trailer, trailer) || !keysKnown(reader, section, signed.section.trailer) { return false }

        var listed = Set<Int>()
        for entry in section.entries where !listed.insert(entry.number).inserted { return false }
        // The size is the first number nothing in the file has (7.5.5).
        if newSize != max(size, max(listed.max() ?? 0, section.streamNumber) + 1) { return false }
        size = newSize
        if !objectsListed(section) || !membersListed(section) { return false }
        if section.streamNumber > 0 { plumbing.insert(section.streamNumber) }
        for entry in section.entries {
            finals[entry.number] = entry
            touched.insert(entry.number)
            if entry.type != 0 { defined.insert(entry.number) }
        }
        return true
    }

    // The keys of an update's trailer are the ones listed, and any other the signed revision's writer left there that the
    // update repeats as it was (our own writers do): a key that points at more cross-reference data never passes.
    private func keysKnown(_ reader: StrictReader, _ section: Section, _ signed: [String: Slice]) -> Bool {
        for (key, value) in section.trailer {
            if Self.trailerKeys.contains(key) || section.streamNumber > 0 && Self.streamKeys.contains(key) { continue }
            if key == "XRefStm" { return false }
            guard let was = signed[key], reader.same(was, value) else { return false }
        }
        return true
    }

    // A reference to an object this update gives, or the one an earlier update gave.
    private func newInfo(_ reader: StrictReader, _ slice: Slice, _ section: Section) -> Bool {
        guard let number = reader.reference(slice) else { return false }
        var given = number == info
        if !given {
            let listed = section.entries.contains { $0.number == number && $0.type != 0 }
            let existed = a.entries[number].map { $0.kind != .free } ?? false
            given = listed && !existed
        }
        if given { info = number }
        return given
    }

    // An update changes the second string of /ID and keeps the first (14.4).
    private func sameId(_ reader: StrictReader, _ before: [String: Slice], _ after: [String: Slice]) -> Bool {
        guard let was = before["ID"], let now = after["ID"] else { return before["ID"] == nil && after["ID"] == nil }
        guard let first = reader.pair(was), let next = reader.pair(now) else { return false }
        return reader.same(first.first, next.first)
    }

    // Each entry in use leads to an "N G obj" of this update with the same number and generation, and each object is listed once.
    private func objectsListed(_ section: Section) -> Bool {
        var byStart: [Int: StrictReader.Indirect] = [:]
        for o in section.objects { byStart[o.start] = o }
        var matched = 0
        for entry in section.entries where entry.type == 1 {
            guard let o = byStart[entry.second], o.number == entry.number, o.generation == entry.third else { return false }
            matched += 1
        }
        return matched == section.objects.count
    }

    private struct Placed: Hashable {
        var number: Int
        var stream: Int
        var index: Int
    }

    // Every member of an object stream the update writes is listed as that member, and nothing else is listed as one.
    private func membersListed(_ section: Section) -> Bool {
        var expected = Set<Placed>()
        let reader = StrictReader(data, data.count)
        for o in section.objects {
            guard o.isStream, let keys = o.keys, let type = keys["Type"], reader.nameOf(type) == "ObjStm" else { continue }
            guard keys["Extends"] == nil, let n = keys["N"], let count = reader.integer(n), let f = keys["First"], let first = reader.integer(f) else { return false }
            guard let decoded = decoded(o.start), let members = Self.members(decoded, count, first) else { return false }
            for (k, member) in members.enumerated() {
                if member.number == o.number { return false }
                expected.insert(Placed(number: member.number, stream: o.number, index: k))
            }
            plumbing.insert(o.number)
        }
        let found = section.entries.filter { $0.type == 2 }.map { Placed(number: $0.number, stream: $0.second, index: $0.third) }
        return found.count == expected.count && found.allSatisfy { expected.contains($0) }
    }

    private static func sameEntry(_ x: PdfDocument.Entry?, _ y: PdfDocument.Entry?) -> Bool {
        let none = PdfDocument.Entry(.free, 0, 0, 0)
        let p = x ?? none, q = y ?? none
        return p.kind == q.kind && p.offset == q.offset && p.generation == q.generation && p.streamNumber == q.streamNumber
    }

    // What the document made of the tables is what the strict read found: no entry moved, none repaired, the chain intact.
    private func tables() -> Bool {
        for (number, entry) in finals {
            let now = b.entries[number] ?? PdfDocument.Entry(.free, 0, 0, 0)
            let same: Bool
            switch entry.type {
            case 0: same = now.kind == .free
            case 1: same = now.kind == .inUse && now.offset == entry.second && now.generation == entry.third
            default: same = now.kind == .compressed && now.streamNumber == entry.second
            }
            if !same { return false }
        }
        for number in Array(a.entries.keys) + Array(b.entries.keys) {
            if finals[number] == nil && !Self.sameEntry(a.entries[number], b.entries[number]) { return false }
        }
        return true
    }

    // The copy of an object the update replaces or frees must itself be exact: another reader may take its odd bytes
    // for something else, and the update then "changes" it into what this reader saw all along.
    private func replaced() -> Bool {
        for number in touched {
            guard let entry = a.entries[number] else { continue }
            if entry.kind == .inUse {
                if entry.offset >= a.source.count { return false }
                let reader = StrictReader(data, a.source.count)
                reader.pos = entry.offset
                reader.lengths = { [self] in signedLength($0) }
                guard let o = reader.object(), o.number == number else { return false }
            } else if entry.kind == .compressed && !signedStreamExact(entry.streamNumber) {
                return false
            }
        }
        return true
    }

    private func signedLength(_ number: Int) -> Int? {
        guard let value = (a.get(number) as? PdfNumber)?.value, !value.isNaN else { return nil }
        if value >= 9.2e18 { return Int.max }
        if value <= -9.2e18 { return Int.min }
        return Int(value)
    }

    private func signedStreamExact(_ number: Int) -> Bool {
        if let known = signedStreams[number] { return known }
        var exact = false
        if let stream = a.get(number) as? PdfStream, let count = a.integer(stream.dictionary, "N"), let first = a.integer(stream.dictionary, "First"),
           let decoded = try? a.data(stream) {
            exact = Self.members(decoded, count, first) != nil
        }
        signedStreams[number] = exact
        return exact
    }
}
