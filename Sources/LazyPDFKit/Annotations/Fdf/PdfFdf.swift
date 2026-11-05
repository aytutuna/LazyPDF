import Foundation

// Twin of windows/LazyPDF.Core/Annotations/Fdf/PdfFdf.cs: reading and writing FDF files (ISO 32000-1 12.7.7), and moving
// annotations between them and a document.
//
// A stream's /Length is added to its start with a checked sum. The C# adds them unchecked, so a /Length near long.Max
// wraps and the read then indexes outside the bytes; here such a /Length is taken as one that does not fit.
// `import` is a keyword in Swift, so that method is written with backticks.

public enum PdfFdf {
    private static let maxObjects = 200_000
    private static let maxFieldDepth = 32

    /// Reads an FDF file. Objects are found by scanning, as the reader does for a damaged PDF, so a file whose table is
    /// wrong still reads. Throws `PdfReadException` (damaged) when no /FDF dictionary is found.
    public static func read(_ data: [UInt8]) throws -> FdfFile {
        let lexer = PdfLexer(PdfArrayBytes(data))
        var objects: [Int: PdfObject] = [:]
        var order: [Int] = []
        var trailer: PdfDictionary?
        var guardCount = 0
        while lexer.position < data.count && guardCount < 4_000_000 {
            guardCount += 1
            lexer.skipWhiteSpace()
            let start = lexer.position
            if start >= data.count { break }
            do {
                if let number = lexer.tryReadUnsigned() {
                    if lexer.tryReadUnsigned() != nil && lexer.readKeyword() == "obj" && number <= Int(Int32.max) {
                        var value = try lexer.readObject()
                        if let stream = value as? PdfStream { value = withData(stream, data, lexer) }
                        if objects.count < maxObjects {
                            if objects[number] == nil { order.append(number) }
                            objects[number] = value
                        }
                    } else {
                        lexer.position = start
                        _ = lexer.readKeyword()
                    }
                } else {
                    let word = lexer.readKeyword()
                    if word == "trailer" {
                        trailer = try lexer.readObject() as? PdfDictionary ?? trailer
                    } else if word.isEmpty {
                        lexer.position += 1
                    }
                }
            } catch is PdfReadException {
                lexer.position = max(lexer.position, start + 1)
            }
        }

        let fdf = FdfFile()
        for number in order { if let value = objects[number] { fdf.add(number, value) } }
        var root = fdf.resolve(trailer?["Root"]) as? PdfDictionary
        if root == nil {
            for number in order {
                if let d = objects[number] as? PdfDictionary, d.containsKey("FDF") {
                    root = d
                    break
                }
            }
        }
        guard let body = fdf.resolve(root?["FDF"]) as? PdfDictionary else {
            throw PdfReadException.damaged("There is no FDF dictionary in the file.")
        }
        // The catalog is rewritten by write; keeping it would leave a second copy of the body behind.
        for (number, value) in fdf.objects where value === root { fdf.objects.removeValue(forKey: number) }

        switch fdf.resolve(body["F"]) {
        case let text as PdfString:
            fdf.fileName = PdfText.decode(text.bytes)
        case let spec as PdfDictionary:
            if let name = fdf.resolve(spec["UF"] ?? spec["F"]) as? PdfString { fdf.fileName = PdfText.decode(name.bytes) }
        default:
            break
        }
        var count = 0
        if let fields = fdf.resolve(body["Fields"]) as? PdfArray { fdf.fields.append(contentsOf: readFields(fdf, fields, 0, &count)) }
        if let annots = fdf.resolve(body["Annots"]) as? PdfArray {
            for item in annots.items.prefix(PdfAnnotations.maxAnnotations) {
                if let d = fdf.resolve(item) as? PdfDictionary, d["Subtype"] is PdfName {
                    let page = min(max((d["Page"] as? PdfNumber)?.integer ?? 0, 0), Int(Int32.max))
                    fdf.annotations.append(FdfAnnotation(page, d))
                }
            }
        }
        return fdf
    }

    private static func withData(_ stream: PdfStream, _ data: [UInt8], _ lexer: PdfLexer) -> PdfObject {
        let start = max(0, min(stream.dataOffset, data.count))
        var end = 0
        var exact = false
        if let length = (stream.dictionary["Length"] as? PdfNumber)?.integer, length >= 0 {
            let (sum, overflow) = start.addingReportingOverflow(length)
            if !overflow && sum <= data.count && endsWithKeyword(data, sum) {
                end = sum
                exact = true
            }
        }
        if !exact {
            end = data.indexOf("endstream".keywordBytes, from: start) ?? data.count
            if end > start && data[end - 1] == 0x0A { end -= 1 }
            if end > start && data[end - 1] == 0x0D { end -= 1 }
        }
        lexer.position = end
        return PdfStream(stream.dictionary, data: Array(data[start..<end]))
    }

    private static func endsWithKeyword(_ data: [UInt8], _ position: Int) -> Bool {
        var at = position
        while at < data.count && PdfLexer.isWhiteSpace(Int(data[at])) { at += 1 }
        return data.hasPattern("endstream".keywordBytes, at: at)
    }

    private static func readFields(_ fdf: FdfFile, _ array: PdfArray, _ depth: Int, _ count: inout Int) -> [FdfField] {
        var fields: [FdfField] = []
        for item in array.items {
            count += 1
            if count - 1 >= maxObjects { break }
            guard let d = fdf.resolve(item) as? PdfDictionary else { continue }
            var name = ""
            if let t = fdf.resolve(d["T"]) as? PdfString { name = PdfText.decode(t.bytes) }
            var kids: [FdfField] = []
            if depth < maxFieldDepth, let k = fdf.resolve(d["Kids"]) as? PdfArray { kids = readFields(fdf, k, depth + 1, &count) }
            fields.append(FdfField(name, fdf.resolve(d["V"]), kids))
        }
        return fields
    }

    /// The file's bytes. The annotations are given objects of their own first (see `FdfFile`).
    public static func write(_ fdf: FdfFile) throws -> [UInt8] {
        try fdf.link()
        var number: [ObjectIdentifier: Int] = [:]
        for n in fdf.objects.keys.sorted() {
            if let dictionary = fdf.objects[n] as? PdfDictionary { number[ObjectIdentifier(dictionary)] = n }
        }
        let body = PdfDictionary()
        if let name = fdf.fileName, !name.isEmpty { body["F"] = PdfText.toObject(name) }
        if !fdf.fields.isEmpty { body["Fields"] = PdfArray(fdf.fields.map { fieldObject($0) }) }
        var annots: [PdfObject] = []
        for annotation in fdf.annotations {
            annotation.dictionary["Page"] = PdfNumber(annotation.pageIndex)
            if let n = number[ObjectIdentifier(annotation.dictionary)] { annots.append(PdfReference(n, 0)) }
        }
        if !annots.isEmpty { body["Annots"] = PdfArray(annots) }

        let highest = fdf.objects.keys.max() ?? 0
        if highest >= Int(Int32.max) { throw PdfReadException.damaged("The FDF data holds too many objects.") }
        let rootNumber = highest + 1
        var output: [UInt8] = []
        put(&output, "%FDF-1.2\n%\u{E2}\u{E3}\u{CF}\u{D3}\n")
        put(&output, "\(rootNumber) 0 obj\n<</FDF \(body)>>\nendobj\n")
        for n in fdf.objects.keys.sorted() {
            guard let value = fdf.objects[n] else { continue }
            if let stream = value as? PdfStream {
                let dictionary = stream.dictionary.copy()
                let payload = stream.data ?? []
                dictionary["Length"] = PdfNumber(payload.count)
                put(&output, "\(n) 0 obj\n\(dictionary)\nstream\n")
                output.append(contentsOf: payload)
                put(&output, "\nendstream\nendobj\n")
            } else {
                put(&output, "\(n) 0 obj\n\(value)\nendobj\n")
            }
        }
        put(&output, "trailer\n<</Root \(rootNumber) 0 R>>\n%%EOF\n")
        return output
    }

    private static func fieldObject(_ field: FdfField) -> PdfObject {
        let d = PdfDictionary()
        d["T"] = PdfText.toObject(field.name)
        if let value = field.value { d["V"] = value }
        if !field.kids.isEmpty { d["Kids"] = PdfArray(field.kids.map { fieldObject($0) }) }
        return d
    }

    private static func put(_ output: inout [UInt8], _ text: String) {
        output.append(contentsOf: Latin1.bytes(text))
    }

    /// The annotations of the document as an FDF file: everything but links and form widgets, with popups, replies,
    /// appearance streams and attachments copied along. `types` narrows them.
    public static func export(_ document: PdfDocument, _ fileName: String? = nil, types: Set<AnnotationType>? = nil) throws -> FdfFile {
        let fdf = FdfFile()
        fdf.fileName = fileName
        var chosen: [PdfAnnotation] = []
        let all = PdfAnnotations.readAll(document)
        var kept = Set<Int>()
        for a in all where a.type != .widget && a.type != .link && a.type != .popup && (types?.contains(a.type) ?? true) {
            chosen.append(a)
            if let r = a.reference { kept.insert(r.number) }
        }
        for popup in all where popup.type == .popup {
            if let p = popup.dictionary["Parent"] as? PdfReference, kept.contains(p.number) { chosen.append(popup) }
        }

        let copier = ObjectCopier(resolve: { document.resolve($0) }, rawData: { document.rawData($0) },
                                  reserve: { try fdf.reserve() }, store: { fdf.store($0, $1) })
        var targets: [PdfReference] = []
        for a in chosen {
            let target = try fdf.reserve()
            targets.append(target)
            if let source = a.reference { copier.preload(source.number, target) }
        }
        let inside = Set(chosen.compactMap { $0.reference?.number })
        for (i, a) in chosen.enumerated() {
            let d = a.dictionary.copy()
            d.remove("P")
            d.remove("StructParent") // a number into the tag tree of this file
            for key in ["Parent", "IRT", "Popup"] {
                if let r = d[key] as? PdfReference, !inside.contains(r.number) { d.remove(key) }
            }
            d["Page"] = PdfNumber(a.pageIndex)
            if !d.containsKey("NM") { d["NM"] = PdfText.toObject(UUID().uuidString.lowercased()) }
            guard let copy = try copier.copy(d) as? PdfDictionary else { continue }
            fdf.store(targets[i], copy)
            fdf.annotations.append(FdfAnnotation(a.pageIndex, copy))
        }
        return fdf
    }

    // The names an annotation of a page has, and the new ones taken from the file; a name of an annotation that is not in
    // the document yet holds nil.
    private final class Taken {
        var names: [String: PdfReference?] = [:]
    }

    /// Adds the annotations of `fdf` to the document. One without an appearance gets one where this layer can draw its
    /// kind; one whose page is not in the document, or whose /NM an annotation of that page already has, is skipped.
    @discardableResult
    public static func `import`(_ document: PdfDocument, _ fdf: FdfFile, _ fonts: FontSource? = nil) throws -> FdfImportResult {
        try fdf.link()
        var accepted: [(source: FdfAnnotation, page: PdfPage, target: PdfReference)] = []
        var names: [Int: Taken] = [:]
        var present: [Int: PdfReference] = [:]
        var skipped = 0
        let copier = ObjectCopier(resolve: { fdf.resolve($0) }, rawData: { $0.data ?? [] },
                                  reserve: { try document.add(PdfNull.instance) }, store: { document.set($0.number, $1) })
        var numberOf: [ObjectIdentifier: Int] = [:]
        for n in fdf.objects.keys.sorted() {
            if let dictionary = fdf.objects[n] as? PdfDictionary { numberOf[ObjectIdentifier(dictionary)] = n }
        }
        var acceptedNumbers = Set<Int>()
        // Popups after the annotations that own them, so that one whose owner was skipped is skipped too.
        let ordered = fdf.annotations.filter { ($0.dictionary["Subtype"] as? PdfName)?.value != "Popup" }
            + fdf.annotations.filter { ($0.dictionary["Subtype"] as? PdfName)?.value == "Popup" }
        for source in ordered {
            let subtype = (source.dictionary["Subtype"] as? PdfName)?.value
            guard let subtype, subtype != "Widget", source.pageIndex >= 0, source.pageIndex < document.pages.count,
                  let sourceNumber = numberOf[ObjectIdentifier(source.dictionary)] else {
                skipped += 1
                continue
            }
            let page = document.pages[source.pageIndex]
            let taken: Taken
            if let known = names[page.index] {
                taken = known
            } else {
                taken = Taken()
                for existing in PdfAnnotations.read(document, page) {
                    if let known = existing.name { taken.names.updateValue(existing.reference, forKey: known) }
                }
                names[page.index] = taken
            }
            if subtype == "Popup", let owner = source.dictionary["Parent"] as? PdfReference, !acceptedNumbers.contains(owner.number) {
                skipped += 1
                continue
            }
            if let nm = source.dictionary["NM"] as? PdfString {
                let key = PdfText.decode(nm.bytes)
                if let entry = taken.names[key] {
                    if let live = entry { present[sourceNumber] = live }
                    skipped += 1
                    continue
                }
                taken.names.updateValue(nil, forKey: key)
            }
            let target = try document.add(PdfNull.instance)
            accepted.append((source, page, target))
            copier.preload(sourceNumber, target)
            acceptedNumbers.insert(sourceNumber)
        }

        let builder = AppearanceBuilder(document, fonts)
        var withoutAppearance = 0
        for (source, page, target) in accepted {
            // A link to an annotation that was not taken would drag it in as a loose object.
            let original = source.dictionary.copy()
            var replyTo: PdfReference?
            for key in ["Parent", "IRT", "Popup"] {
                if let r = original[key] as? PdfReference, !acceptedNumbers.contains(r.number) {
                    // A reply to an annotation the document already had is a reply to that one.
                    if key == "IRT" { replyTo = present[r.number] }
                    original.remove(key)
                }
            }
            guard let d = try copier.copy(original) as? PdfDictionary else { continue }
            if let replyTo {
                d["IRT"] = replyTo
            } else if let by = d["IRT"] as? PdfString {
                if let entry = names[page.index]?.names[PdfText.decode(by.bytes)], let named = entry {
                    d["IRT"] = named
                } else {
                    d.remove("IRT")
                }
            }
            d.remove("Page")
            d["P"] = page.reference
            document.set(target.number, d)
            if let list = document.array(page.dictionary, "Annots") {
                list.items.append(target)
            } else {
                page.dictionary["Annots"] = PdfArray([target])
            }
            if d["AP"] == nil, let parsed = PdfAnnotations.parse(document, d, target), AppearanceBuilder.canDraw(parsed.type) {
                do {
                    if !(try builder.apply(d)) { withoutAppearance += 1 }
                } catch is InvalidOperationException {
                    withoutAppearance += 1
                }
            }
        }
        return FdfImportResult(imported: accepted.count, skipped: skipped, withoutAppearance: withoutAppearance)
    }
}

/// What `PdfFdf.import` did: annotations added, entries skipped, and added ones left without an appearance.
public struct FdfImportResult: Equatable {
    public let imported: Int
    public let skipped: Int
    public let withoutAppearance: Int
}
