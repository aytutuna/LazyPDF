import Foundation

// Twin of windows/LazyPDF.Core/Document/PdfRewriter.cs: a rewrite keeps what the trailer can reach, numbers it
// afresh and lays the file out again, with no history in it. Reachability is a walk from /Root and /Info; the
// numbers come out in the order the walk meets the objects, which puts the catalog first.
//
// The deflated bytes (object streams, a cross-reference stream, a stream that is repacked) are the engine's own
// Deflate and differ from .NET's, so a file saved here is not byte for byte the C#'s wherever one is written.

public final class PdfRewriter {
    // The size qpdf and most writers pack to; an object stream is parsed whole to read one object.
    private static let objectsPerStream = 100

    private static let repackable = ["FlateDecode", "Fl", "LZWDecode", "LZW", "ASCII85Decode", "A85", "ASCIIHexDecode", "AHx", "RunLengthDecode", "RL"]

    private let document: PdfDocument
    private let options: PdfSaveOptions
    private var numbers: [Int: Int] = [:]
    private var items: [PdfObject] = []
    private var followed = 0

    /// The numbers reached that the table lists and that could not be read.
    private(set) var dropped = Set<Int>()

    public init(_ document: PdfDocument, _ options: PdfSaveOptions) {
        self.document = document
        self.options = options
    }

    public func run() throws -> [UInt8] {
        let root = intern(document.trailer["Root"])
        let info = document.info == nil ? 0 : intern(document.trailer["Info"])
        follow()
        // Pages the reader shows without the tree reaching them (it found them by scanning) are kept too.
        for page in document.pages { _ = intern(page.reference) }
        follow()

        let security = options.security
        var packed: [Int] = []
        if options.useObjectStreams {
            // The catalog stays a plain object: PdfPig asks for it before it can decrypt an object stream.
            for n in stride(from: 1, through: items.count, by: 1) where n != root {
                let item = items[n - 1]
                if item is PdfStream { continue }
                if let dictionary = item as? PdfDictionary, PdfDocument.isSignature(dictionary) { continue }
                packed.append(n)
            }
        }
        let packedSet = Set(packed)
        var next = items.count + 1
        let firstStream = next
        next += (packed.count + Self.objectsPerStream - 1) / Self.objectsPerStream
        var encryptNumber = 0
        if security != nil {
            encryptNumber = next
            next += 1
        }
        var xrefNumber = 0
        if options.useObjectStreams {
            xrefNumber = next
            next += 1
        }

        let writer = PdfObjectWriter(position: 0, security: security)
        writer.writeHeader(headerVersion())
        var entries = [XrefEntry(0, 0, 0, 65535)]

        for n in stride(from: 1, through: items.count, by: 1) {
            if n % 256 == 0 { try Task.checkCancellation() }
            if packedSet.contains(n) { continue }
            let at: Int
            if let stream = items[n - 1] as? PdfStream {
                let dictionary = remapDictionary(stream.dictionary, true)
                let dropped = security !== document.security && dropCrypt(stream, dictionary)
                let view = security == nil || dropped ? nil : document.cryptView(stream.dictionary)
                let stored = self.stored(stream, dictionary)
                at = writer.writeStream(n, 0, dictionary, stored, cryptView: view)
            } else {
                at = writer.writeObject(n, 0, remap(items[n - 1]))
            }
            entries.append(XrefEntry(n, 1, at, 0))
        }
        var s = 0
        while s * Self.objectsPerStream < packed.count {
            try Task.checkCancellation()
            let members = Array(packed.dropFirst(s * Self.objectsPerStream).prefix(Self.objectsPerStream))
            let number = firstStream + s
            let (dictionary, data) = pack(members)
            entries.append(XrefEntry(number, 1, writer.writeStream(number, 0, dictionary, data), 0))
            for (i, member) in members.enumerated() { entries.append(XrefEntry(member, 2, number, i)) }
            s += 1
        }
        if let security {
            entries.append(XrefEntry(encryptNumber, 1, writer.writeObject(encryptNumber, 0, security.dictionary, encrypt: false), 0))
        }

        let trailer = PdfDictionary()
        trailer.add("Size", PdfNumber(next))
        trailer.add("Root", PdfReference(root, 0))
        if info > 0 { trailer.add("Info", PdfReference(info, 0)) }
        if security != nil { trailer.add("Encrypt", PdfReference(encryptNumber, 0)) }
        trailer.add("ID", PdfXrefWriter.idPair(firstId()))
        entries.sort { $0.number < $1.number }
        if xrefNumber > 0 {
            PdfXrefWriter.writeStream(writer, xrefNumber, entries, trailer, compress: true)
        } else {
            PdfXrefWriter.writeTable(writer, entries, trailer)
        }
        return writer.output
    }

    private func follow() {
        while followed < items.count {
            if let stream = items[followed] as? PdfStream {
                visit(stream.dictionary, true)
            } else {
                visit(items[followed], false)
            }
            followed += 1
        }
    }

    /// A new handler has no crypt filters of the old one's names, so the stream's Crypt stage goes; the data is
    /// already decrypted.
    private func dropCrypt(_ stream: PdfStream, _ dictionary: PdfDictionary) -> Bool {
        let (filter, parameters, crypt) = document.decodeSpec(stream)
        if !crypt { return false }
        dictionary.remove("DecodeParms")
        if filter == nil || (filter as? PdfArray)?.items.isEmpty == true {
            dictionary.remove("Filter")
            return true
        }
        dictionary["Filter"] = filter.map(remap)
        if let parameters, !(parameters is PdfNull) { dictionary["DecodeParms"] = remap(parameters) }
        return true
    }

    /// The number the object `entry` names or is gets in the new file; 0 for nothing there.
    private func intern(_ entry: PdfObject?) -> Int {
        if let reference = entry as? PdfReference {
            if let known = numbers[reference.number] { return known }
            guard let value = document.get(reference.number), !(value is PdfNull) else {
                if let listed = document.entries[reference.number], listed.kind == .inUse || listed.kind == .compressed { dropped.insert(reference.number) }
                return 0
            }
            items.append(value)
            numbers[reference.number] = items.count
            return items.count
        }
        guard let direct = document.resolve(entry) else { return 0 }
        items.append(direct)
        return items.count
    }

    /// Numbers the objects a value refers to. A stream's /Length is not followed: it is written afresh.
    private func visit(_ value: PdfObject, _ stream: Bool) {
        switch value {
        case is PdfReference:
            _ = intern(value)
        case let array as PdfArray:
            for item in array.items { visit(item, false) }
        case let dictionary as PdfDictionary:
            for (key, item) in dictionary.entries where !(stream && key == "Length") { visit(item, false) }
        default:
            break
        }
    }

    /// The value with its references renumbered; one to an object that is not there is dropped from a dictionary
    /// and null in an array.
    private func remap(_ value: PdfObject) -> PdfObject {
        switch value {
        case let reference as PdfReference:
            return numbers[reference.number].map { PdfReference($0, 0) as PdfObject } ?? PdfNull.instance
        case let array as PdfArray:
            return PdfArray(array.items.map { remap($0) })
        case let dictionary as PdfDictionary:
            return remapDictionary(dictionary, false)
        case let stream as PdfStream:
            // A stream the flattened parameters met (/JBIG2Globals) is written as the reference it came from.
            return numbers[stream.number].map { PdfReference($0, 0) as PdfObject } ?? PdfNull.instance
        default:
            return value
        }
    }

    private func remapDictionary(_ source: PdfDictionary, _ stream: Bool) -> PdfDictionary {
        let copy = PdfDictionary()
        for (key, item) in source.entries {
            if source[key] !== item || (stream && key == "Length") { continue }
            let mapped = remap(item)
            if !(mapped is PdfNull) { copy.add(key, mapped) }
        }
        return copy
    }

    private func pack(_ members: [Int]) -> (dictionary: PdfDictionary, data: [UInt8]) {
        var header = ""
        let body = PdfObjectWriter()
        for number in members {
            header.append("\(number) \(body.position) ")
            body.writeDirect(remap(items[number - 1]))
            body.writeAscii("\n")
        }
        let first = Latin1.bytes(header)
        let dictionary = PdfDictionary()
        dictionary.add("Type", PdfName("ObjStm"))
        dictionary.add("N", PdfNumber(members.count))
        dictionary.add("First", PdfNumber(first.count))
        dictionary.add("Filter", PdfName("FlateDecode"))
        return (dictionary, PdfFilterEncoders.flate(first + body.output))
    }

    /// The data to store for a stream. What is not compressed, or only by the old text filters, is deflated when
    /// that is smaller. A stream with a predictor is left (deflating without it would lose more than it gains),
    /// as are Flate streams already, metadata, and image data, which is never touched.
    private func stored(_ stream: PdfStream, _ dictionary: PdfDictionary) -> [UInt8] {
        let raw = document.rawData(stream)
        if !canRepack(stream.dictionary) { return raw }
        let plain: [UInt8]
        do {
            plain = try document.data(stream, PdfFilters.defaultMaxSize, strict: true)
        } catch {
            return raw
        }
        let deflated = PdfFilterEncoders.flate(plain)
        if deflated.count >= raw.count { return raw }
        dictionary["Filter"] = PdfName("FlateDecode")
        dictionary.remove("DecodeParms")
        return deflated
    }

    private func canRepack(_ dictionary: PdfDictionary) -> Bool {
        if let type = document.name(dictionary, "Type"), type == "Metadata" || type == "XRef" || type == "ObjStm" { return false }
        let filters: [String]
        switch document.resolve(dictionary["Filter"]) {
        case nil: filters = []
        case let name as PdfName: filters = [name.value]
        case let array as PdfArray: filters = array.items.map { (document.resolve($0) as? PdfName)?.value ?? "" }
        default: filters = [""]
        }
        if filters.count == 1 && (filters[0] == "FlateDecode" || filters[0] == "Fl") { return false }
        if !filters.allSatisfy({ Self.repackable.contains($0) }) { return false }
        let parameters = document.resolve(dictionary["DecodeParms"])
        var each: [PdfObject?] = [parameters]
        if let list = parameters as? PdfArray { each = list.items }
        return !each.contains { (document.integer(document.resolve($0) as? PdfDictionary, "Predictor") ?? 0) > 1 }
    }

    private func firstId() -> [UInt8] {
        // The keys of the older handlers are made from the first string, so a kept handler keeps it.
        if let security = options.security, security === document.security { return document.firstId ?? [] }
        // The first string names the document across its versions (ISO 32000-1 14.4.1).
        if options.documentId == nil, options.security == nil, let kept = document.firstId, !kept.isEmpty { return kept }
        return options.documentId ?? PdfSecurity.systemRandom(16)
    }

    private func headerVersion() -> String {
        var version = document.version
        if options.useObjectStreams { version = Self.raised(version, "1.5") }
        if let revision = options.security?.revision {
            if revision >= 5 {
                version = Self.raised(version, "1.7")
            } else if revision == 4 {
                version = Self.raised(version, "1.6")
            }
        }
        return version
    }

    private static func raised(_ version: String, _ least: String) -> String {
        if let v = SystemVersion(version), let l = SystemVersion(least), v >= l { return version }
        return least
    }
}
