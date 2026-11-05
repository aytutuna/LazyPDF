import Foundation

// Twin of windows/LazyPDF.Core/Stamps/StampRuns.cs: run ids are only unique within the file that made them. Pages brought
// together from several files can carry the same id for different runs; they are given ids of their own, so that removing
// one run does not take another with it.

enum StampRuns {
    private static let maxContent = 64 << 20

    private struct Origin: Hashable {
        let file: ObjectIdentifier
        let id: Int
    }

    private struct Signature: Equatable {
        let kind: StampKind
        let label: String?
        let behind: Bool

        // The C# compares labels ordinally; String's == treats canonically equivalent text as equal.
        static func == (a: Signature, b: Signature) -> Bool {
            guard a.kind == b.kind, a.behind == b.behind else { return false }
            switch (a.label, b.label) {
            case (nil, nil): return true
            case let (x?, y?): return x.unicodeScalars.elementsEqual(y.unicodeScalars)
            default: return false
            }
        }
    }

    /// Pages in their final order, each with the file it came from.
    static func separate(_ document: PdfDocument, _ pages: [(page: PdfPage, origin: AnyObject)]) throws {
        var claimed: [Int: Signature] = [:]
        var renamed: [Origin: Int] = [:]
        var done = Set<ObjectIdentifier>()
        var used = Set(pages.flatMap { StampStreams.scan(document, $0.page) }.map { $0.id })
        for (page, origin) in pages {
            for found in StampStreams.scan(document, page) {
                let signature = Signature(kind: found.kind, label: found.label, behind: found.behind)
                let from = Origin(file: ObjectIdentifier(origin), id: found.id)
                if let already = renamed[from] {
                    if already != found.id { try renumber(document, page, found.id, already, &done) }
                    continue
                }
                var id = found.id
                if let holder = claimed[id], holder != signature {
                    id = StampStreams.spare(used)
                    used.insert(id)
                    try renumber(document, page, found.id, id, &done)
                }
                claimed[id] = signature
                renamed[from] = id
            }
        }
    }

    private static func renumber(_ document: PdfDocument, _ page: PdfPage, _ from: Int, _ to: Int, _ done: inout Set<ObjectIdentifier>) throws {
        for item in StampStreams.contents(document, page) {
            guard let stream = document.resolve(item) as? PdfStream else { continue }
            guard let marker = document.dict(stream.dictionary, StampStreams.key), StampStreams.idOf(document, marker) == from,
                  done.insert(ObjectIdentifier(stream)).inserted else { continue }
            marker["Id"] = PdfNumber(to)
            var text = Latin1.string(try document.data(stream, maxContent))
            text = text.replacingOccurrences(of: StampStreams.prefix(from), with: StampStreams.prefix(to), options: .literal)
            stream.data = Latin1.bytes(renumberMarker(text, from, to))
            stream.dictionary.remove("Filter")
            stream.dictionary.remove("DecodeParms")
        }
        guard let resources = document.dict(page.dictionary, "Resources") else { return }
        let start = StampStreams.prefix(from)
        for category in ["Font", "XObject", "ExtGState", "Properties"] {
            guard let entries = document.dict(resources, category) else { continue }
            for (name, value) in entries.entries where name.hasPrefix(start) {
                entries.remove(name)
                entries[StampStreams.prefix(to) + String(name.unicodeScalars.dropFirst(start.unicodeScalars.count))] = value
                if category == "Properties", let group = document.resolve(value) as? PdfDictionary,
                   done.insert(ObjectIdentifier(group)).inserted, document.integer(group, StampStreams.key) == from {
                    group[StampStreams.key] = PdfNumber(to)
                }
            }
        }
    }

    // The C# does this with the pattern (/LazyPDF\s+)<from>(?!\d); \s is what .NET counts as white space.
    static func renumberMarker(_ text: String, _ from: Int, _ to: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        let key = Array("/\(StampStreams.key)".unicodeScalars)
        let number = Array(String(from).unicodeScalars)
        var result = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i...].starts(with: key) {
                var k = i + key.count
                while k < scalars.count, isWhite(scalars[k]) { k += 1 }
                let end = k + number.count
                if k > i + key.count, scalars[k...].starts(with: number), end >= scalars.count || !isDigit(scalars[end]) {
                    result.append(contentsOf: scalars[i..<k])
                    result.append(contentsOf: String(to).unicodeScalars)
                    i = end
                    continue
                }
            }
            result.append(scalars[i])
            i += 1
        }
        return String(result)
    }

    private static func isWhite(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 9 && c.value <= 13) || c == " " || c.value == 0x85 || c.value == 0xA0
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
}
