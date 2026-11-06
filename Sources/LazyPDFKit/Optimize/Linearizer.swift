import Foundation

// Twin of windows/LazyPDF.Core/Optimize/Linearizer.cs: linearized output (ISO 32000-1 Annex F). In file order:
// header, the linearization dictionary, the first-page cross-reference section, the catalog, the hint stream, the
// first page's objects, the other pages one after the other, shared objects, everything else, and the main
// cross-reference section. Objects are numbered in file order, the main section's first, so that each section is
// one run of numbers.
//
// The C# is a partial class; the stored properties of all its parts are declared here, as Swift extensions cannot
// hold them. The file is built in an array in place of the MemoryStream, and a list shared by two names in the C#
// (the first page's objects are `_part6`) is one array that is copied back where it changes.

final class Linearizer {
    // The fields written last (lengths, offsets) take this many characters whatever their value,
    // so that sizes are known before the numbers are.
    static let fieldWidth = 10

    // The file is built in one array, and the hint stream and cross-reference sections come on top of the objects.
    static let maxSize = Int(Int32.max) - (64 << 20)

    // The cap on object visits over all walks. A page's walk sees everything it uses, shared or not,
    // so the total is about the size of the hint tables.
    static let maxVisits = 100_000_000
    static let maxDepth = 256

    // Page tree attributes a page takes from its ancestors (7.7.3.4). Hint tables describe a page by
    // the objects it reaches, so they have to be on the page itself.
    static let inherited = ["Resources", "MediaBox", "CropBox", "Rotate"]

    static let openKeys = ["ViewerPreferences", "PageMode", "Threads", "OpenAction", "AcroForm"]

    // Where in a page its first reference to a shared object lies is not tracked: every fraction is 0 of 4.
    static let fractionDenominator = 4

    let document: PdfDocument
    let options: PdfSaveOptions

    var blob: [UInt8] = []
    var start: [Int] = []
    var length: [Int] = []
    var number: [Int] = []
    var linNumber = 0
    var hintNumber = 0
    var size = 0
    var id = PdfArray([])

    var items: [PdfObject] = []
    var oldNumbers: [Int] = []
    var children: [[Int]] = []
    var index: [Int: Int] = [:]
    var pageNumbers = Set<Int>()
    var made: [Int: PdfObject] = [:]
    var promoted: [ObjectIdentifier: PdfReference] = [:]
    var stack: [Int] = []
    var followed = 0
    var nextMade = 0
    var visits = 0

    var pageItem: [Int] = []
    var root = 0
    var info = -1
    var encrypt = -1
    var part4: [Int] = []
    var outlines: [Int] = []
    var part6: [Int] = []
    var part8: [Int] = []
    var part9: [Int] = []
    var pageObjects: [[Int]] = []
    var pageShared: [[Int]] = []

    init(_ document: PdfDocument, _ options: PdfSaveOptions) {
        self.document = document
        self.options = options
    }

    func run() throws -> [UInt8] {
        try collect()
        try classify()
        numberObjects()
        try serialize()
        return try assemble()
    }

    private func numberObjects() {
        number = Array(repeating: 0, count: items.count)
        var next = 1
        for p in stride(from: 1, to: pageObjects.count, by: 1) {
            for o in pageObjects[p] {
                number[o] = next
                next += 1
            }
        }
        for o in part8 {
            number[o] = next
            next += 1
        }
        for o in part9 {
            number[o] = next
            next += 1
        }
        linNumber = next
        next += 1
        for o in part4 {
            number[o] = next
            next += 1
        }
        hintNumber = next
        next += 1
        for o in part6 {
            number[o] = next
            next += 1
        }
        size = next
    }

    private func serialize() throws {
        let security = options.security
        let writer = PdfObjectWriter(position: 0, security: security)
        start = Array(repeating: 0, count: items.count)
        length = Array(repeating: 0, count: items.count)
        for o in 0..<items.count {
            start[o] = writer.position
            if let stream = items[o] as? PdfStream {
                let dictionary = remapDictionary(stream.dictionary, true)
                let dropped = security !== document.security && dropCrypt(stream, dictionary)
                let view = security == nil || dropped ? nil : document.cryptView(stream.dictionary)
                let data = document.rawData(stream)
                if writer.position + data.count > Self.maxSize { throw PdfReadException(.unsupported, "The file is too large to linearize.") }
                writer.writeStream(number[o], 0, dictionary, data, cryptView: view)
            } else {
                writer.writeObject(number[o], 0, remap(items[o]), encrypt: o != encrypt)
            }
            length[o] = writer.position - start[o]
        }
        blob = writer.output
    }

    private func remap(_ value: PdfObject) -> PdfObject {
        switch value {
        case let reference as PdfReference:
            if let item = index[reference.number] { return PdfReference(number[item], 0) }
            return PdfNull.instance
        case let array as PdfArray:
            return PdfArray(array.items.map { remap($0) })
        case let dictionary as PdfDictionary:
            return remapDictionary(dictionary, false)
        case let number as PdfNumber:
            // An integer too big for 64 bits is a real as far as a strict reader is concerned.
            if number.isInteger && number.integer == nil && number.value != 0 && number.value.isFinite { return PdfNumber(number.text + ".0") }
            return value
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

    // As in PdfRewriter: a new handler has no crypt filter of the old one's names, and the data is already decrypted.
    private func dropCrypt(_ stream: PdfStream, _ dictionary: PdfDictionary) -> Bool {
        let (filter, parameters, crypt) = document.decodeSpec(stream)
        if !crypt { return false }
        dictionary.remove("DecodeParms")
        if filter == nil || (filter as? PdfArray)?.items.isEmpty == true {
            dictionary.remove("Filter")
            return true
        }
        dictionary["Filter"] = filter
        if let parameters, !(parameters is PdfNull) { dictionary["DecodeParms"] = parameters }
        return true
    }

    private func assemble() throws -> [UInt8] {
        guard let firstOfPage = part6.first else { throw PdfReadException.damaged("The first page has no objects.") }
        id = PdfXrefWriter.idPair(firstId())
        let header = headerBytes()
        let linLength = linearization(0, 0, 0, 0, 0, 0, 0).count
        let firstCount = part4.count + part6.count + 2
        let firstHead = "xref\n\(linNumber) \(firstCount)\n"
        let firstXref = header.count + linLength
        var position = firstXref + firstHead.utf8.count + 20 * firstCount + firstTrailer(0).count

        var at = Array(repeating: 0, count: items.count)
        for o in part4 {
            at[o] = position
            position += length[o]
        }
        // Offsets in the hint tables count the file as if the hint stream were not in it (F.3.3), so
        // the layout is made without it first and moved by its length once that is known.
        let hintAt = position
        let behind = behindHint()
        for o in behind {
            at[o] = position
            position += length[o]
        }
        let hint = hintStream(at)
        for o in behind { at[o] += hint.count }
        let firstPageEnd = hintAt + hint.count + part6.reduce(0) { $0 + length[$1] }
        let mainAt = position + hint.count

        var offsets = Array(repeating: 0, count: size)
        for o in 0..<items.count { offsets[number[o]] = at[o] }
        offsets[linNumber] = header.count
        offsets[hintNumber] = hintAt
        let main = mainSection(offsets, firstXref)
        let total = mainAt + main.count
        if total > Int(Int32.max) { throw PdfReadException(.unsupported, "The file is too large to linearize.") }
        let lin = linearization(total, hintAt, hint.count, number[firstOfPage], firstPageEnd, pageItem.count, mainAt + "xref\n".utf8.count + "0 \(linNumber)".utf8.count)

        var output: [UInt8] = []
        output.reserveCapacity(total)
        output += header
        output += lin
        var first = firstHead
        for n in linNumber..<size { first += Self.entry(offsets[n]) }
        output += Latin1.bytes(first)
        output += firstTrailer(mainAt)
        for o in part4 { append(&output, o) }
        output += hint
        for o in behind { append(&output, o) }
        output += main
        return output
    }

    /// The objects after the hint stream, in file order.
    private func behindHint() -> [Int] {
        var order = part6
        for p in stride(from: 1, to: pageObjects.count, by: 1) { order += pageObjects[p] }
        order += part8
        order += part9
        return order
    }

    private func append(_ output: inout [UInt8], _ item: Int) {
        output += blob[start[item]..<start[item] + length[item]]
    }

    private static func entry(_ offset: Int) -> String {
        let digits = String(offset)
        return String(repeating: "0", count: Swift.max(0, 10 - digits.count)) + digits + " 00000 n \n"
    }

    private func headerBytes() -> [UInt8] {
        let writer = PdfObjectWriter()
        writer.writeHeader(headerVersion())
        return writer.output
    }

    /// The linearization parameter dictionary (F.3.2), padded to the size it has with the widest values.
    private func linearization(_ l: Int, _ hintAt: Int, _ hintLength: Int, _ firstPage: Int, _ end: Int, _ pages: Int, _ mainFirst: Int) -> [UInt8] {
        func text(_ l: Int, _ h0: Int, _ h1: Int, _ o: Int, _ e: Int, _ n: Int, _ t: Int) -> String {
            "\(linNumber) 0 obj\n<< /Linearized 1 /L \(l) /H [ \(h0) \(h1) ] /O \(o) /E \(e) /N \(n) /T \(t)"
        }
        let widest = 9_999_999_999
        let used = text(l, hintAt, hintLength, firstPage, end, pages, mainFirst)
        let room = text(widest, widest, widest, widest, widest, widest, widest).utf8.count - used.utf8.count
        return Latin1.bytes(used + String(repeating: " ", count: Swift.max(0, room)) + " >>\nendobj\n")
    }

    private func firstTrailer(_ previous: Int) -> [UInt8] {
        var text = "trailer\n<< /Size \(size) /Root \(number[root]) 0 R"
        if info >= 0 { text += " /Info \(number[info]) 0 R" }
        if encrypt >= 0 { text += " /Encrypt \(number[encrypt]) 0 R" }
        text += " /ID "
        id.writeTo(&text)
        let padded = String(previous) + String(repeating: " ", count: Swift.max(0, Self.fieldWidth - String(previous).count))
        text += " /Prev \(padded) >>\nstartxref\n0\n%%EOF\n"
        return Latin1.bytes(text)
    }

    private func mainSection(_ offsets: [Int], _ firstXref: Int) -> [UInt8] {
        var text = "xref\n0 \(linNumber)\n0000000000 65535 f \n"
        for n in stride(from: 1, to: linNumber, by: 1) { text += Self.entry(offsets[n]) }
        text += "trailer\n<< /Size \(linNumber) /ID "
        id.writeTo(&text)
        text += " >>\nstartxref\n\(firstXref)\n%%EOF\n"
        return Latin1.bytes(text)
    }

    private func firstId() -> [UInt8] {
        // The keys of the older handlers are made from the first string, so a kept handler keeps it.
        if let security = options.security, security === document.security { return document.firstId ?? [] }
        // The first string names the document across its versions (ISO 32000-1 14.4.1).
        if options.documentId == nil, options.security == nil, let kept = document.firstId, !kept.isEmpty { return kept }
        return options.documentId ?? PdfSecurity.systemRandom(16)
    }

    private func headerVersion() -> String {
        var version = Self.raised(document.version, "1.2")
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
