import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeResources.cs: drops the resources a page or form lists but its
// content never names. A resource dictionary shared by several owners keeps what any of them uses; one whose content
// cannot be read is left whole.

final class OptimizeResources {
    private static let categories = ["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"]
    private static let maxDepth = 8

    private final class Usage {
        let resources: PdfDictionary
        var names: [String: Set<String>] = Dictionary(uniqueKeysWithValues: OptimizeResources.categories.map { ($0, Set<String>()) })
        var isUnsafe = false

        init(_ resources: PdfDictionary) { self.resources = resources }
    }

    private let document: PdfDocument
    private var usage: [ObjectIdentifier: Usage] = [:]
    private var order: [Usage] = []

    init(_ document: PdfDocument) {
        self.document = document
    }

    func run() -> Int {
        for dictionary in PdfGraph.allDictionaries(document) {
            if document.name(dictionary, "Subtype") != "Type3" { continue }
            guard let own = document.dict(dictionary, "Resources") else { return 0 }
            usageOf(own).isUnsafe = true
        }
        for page in document.pages {
            guard let resources = page.resources else { continue }
            let used = usageOf(resources)
            collectPage(page, resources, used)
            for stream in appearancesWithoutResources(page) { collectStream(stream, resources, used) }
        }
        for (_, value) in PdfGraph.objects(document) {
            guard let stream = value as? PdfStream, let resources = document.dict(stream.dictionary, "Resources") else { continue }
            if document.name(stream.dictionary, "Subtype") != "Form" && document.integer(stream.dictionary, "PatternType") != 1 { continue }
            collectStream(stream, resources, usageOf(resources))
        }
        var removed = 0
        for used in order {
            if used.isUnsafe { continue }
            for category in Self.categories {
                guard let entries = document.dict(used.resources, category) else { continue }
                for (name, _) in entries.entries {
                    if used.names[category]?.contains(name) == true || (category == "ColorSpace" && name.hasPrefix("Default")) { continue }
                    entries.remove(name)
                    removed += 1
                }
            }
        }
        return removed
    }

    private func usageOf(_ resources: PdfDictionary) -> Usage {
        if let known = usage[ObjectIdentifier(resources)] { return known }
        let created = Usage(resources)
        usage[ObjectIdentifier(resources)] = created
        order.append(created)
        return created
    }

    private func collectStream(_ stream: PdfStream, _ resources: PdfDictionary, _ used: Usage) {
        do {
            var seen = Set<ObjectIdentifier>()
            try collect(document.data(stream), resources, used, 0, &seen)
        } catch {
            used.isUnsafe = true
        }
    }

    // An operator may sit in a later stream than its operands (7.8.2), so the streams are read as one.
    private func collectPage(_ page: PdfPage, _ resources: PdfDictionary, _ used: Usage) {
        let contents = document.resolve(page.dictionary["Contents"])
        var joined: [UInt8] = []
        let items: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
        do {
            for item in items {
                guard let part = document.resolve(item) as? PdfStream else { continue }
                joined += try document.data(part)
                joined.append(UInt8(ascii: "\n"))
            }
            var seen = Set<ObjectIdentifier>()
            try collect(joined, resources, used, 0, &seen)
        } catch {
            used.isUnsafe = true
        }
    }

    // Appearance streams written without /Resources borrow the page's.
    private func appearancesWithoutResources(_ page: PdfPage) -> [PdfStream] {
        var found: [PdfStream] = []
        for item in document.array(page.dictionary, "Annots")?.items ?? [] {
            guard let ap = document.dict(document.resolve(item) as? PdfDictionary, "AP") else { continue }
            for (_, state) in ap.entries {
                let resolved = document.resolve(state)
                let streams: [PdfObject?] = (resolved as? PdfDictionary).map { $0.entries.map { document.resolve($0.value) } } ?? [resolved]
                for candidate in streams {
                    if let s = candidate as? PdfStream, document.dict(s.dictionary, "Resources") == nil { found.append(s) }
                }
            }
        }
        return found
    }

    private func collect(_ content: [UInt8], _ resources: PdfDictionary, _ used: Usage, _ depth: Int, _ seen: inout Set<ObjectIdentifier>) {
        for op in ContentParser.parse(content) {
            switch op.operator {
            case "Do":
                guard let xobject = Self.name(op, 0) else { break }
                used.names["XObject"]?.insert(xobject)
                // A form with no resources of its own runs in its caller's.
                if let xobjects = document.dict(resources, "XObject"), let form = document.resolve(xobjects[xobject]) as? PdfStream,
                   document.name(form.dictionary, "Subtype") == "Form", document.dict(form.dictionary, "Resources") == nil,
                   seen.insert(ObjectIdentifier(form)).inserted {
                    if depth >= Self.maxDepth {
                        used.isUnsafe = true
                        break
                    }
                    do {
                        try collect(document.data(form), resources, used, depth + 1, &seen)
                    } catch {
                        used.isUnsafe = true
                    }
                }
            case "Tf":
                if let font = Self.name(op, 0) { used.names["Font"]?.insert(font) }
            case "gs":
                if let state = Self.name(op, 0) { used.names["ExtGState"]?.insert(state) }
            case "cs", "CS":
                if let space = Self.name(op, 0) { used.names["ColorSpace"]?.insert(space) }
            case "sc", "scn", "SC", "SCN":
                if let pattern = op.operands.last as? PdfName { used.names["Pattern"]?.insert(pattern.value) }
            case "sh":
                if let shading = Self.name(op, 0) { used.names["Shading"]?.insert(shading) }
            case "BDC", "DP":
                if op.operands.count >= 2, let property = op.operands.last as? PdfName { used.names["Properties"]?.insert(property.value) }
            case "BI":
                guard let image = op.image else { break }
                // An indexed inline image names its base space in the array (8.9.7).
                var inlineSpace = image.dictionary["CS"] ?? image.dictionary["ColorSpace"]
                if let indexed = inlineSpace as? PdfArray, indexed.items.count > 1 { inlineSpace = indexed.items[1] }
                if let inlineName = inlineSpace as? PdfName { used.names["ColorSpace"]?.insert(inlineName.value) }
            default:
                break
            }
        }
    }

    private static func name(_ op: ContentOperation, _ index: Int) -> String? {
        op.operands.count > index ? (op.operands[index] as? PdfName)?.value : nil
    }
}
