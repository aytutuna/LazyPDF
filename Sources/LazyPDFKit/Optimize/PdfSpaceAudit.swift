import Foundation

// Twin of windows/LazyPDF.Core/Optimize/PdfSpaceAudit.cs: gives every object of a file to the kind of content it
// serves. An object met from several places belongs to the first of the seeds below that reaches it.

final class PdfSpaceAudit {
    private static let backLinks: Set<String> = ["Parent", "P", "Pg"]

    private let document: PdfDocument
    private var assigned: [Int: SpaceKind] = [:]
    private var bytes: [SpaceKind: Int] = Dictionary(uniqueKeysWithValues: SpaceKind.allCases.map { ($0, 0) })

    init(_ document: PdfDocument) {
        self.document = document
    }

    func run() -> SpaceAudit {
        let catalog = document.catalog
        walk(document.trailer["Info"], .metadata)
        walk(catalog["Metadata"], .metadata)
        let names = document.dict(catalog, "Names")
        walk(names?["EmbeddedFiles"], .attachments)
        walk(catalog["AF"], .attachments)
        walk(catalog["AcroForm"], .forms)
        walk(catalog["Pages"], .content, skip: "Annots")
        for page in document.pages { walk(page.dictionary["Annots"], .annotations) }
        walk(document.trailer["Root"], .structure)

        for number in document.objectNumbers {
            if assigned[number] != nil { continue }
            guard let value = document.get(number) else { continue }
            bytes[.unreferenced, default: 0] += PdfGraph.sizeOf(document, value)
        }
        let accounted = bytes.values.reduce(0, +)
        bytes[.overhead] = max(0, document.length - accounted)
        return SpaceAudit(document.length, bytes)
    }

    private func walk(_ start: PdfObject?, _ kind: SpaceKind, skip: String? = nil) {
        guard let start else { return }
        var stack: [(value: PdfObject, kind: SpaceKind, depth: Int)] = [(start, kind, 0)]
        while let (value, kind, depth) = stack.popLast() {
            var current = kind
            if depth > 200 { continue }
            if let reference = value as? PdfReference {
                if assigned[reference.number] != nil { continue }
                guard let target = document.get(reference.number) else { continue }
                current = overridden(target, current)
                assigned[reference.number] = current
                bytes[current, default: 0] += PdfGraph.sizeOf(document, target)
                stack.append((target, current, depth + 1))
                continue
            }
            if let direct = value as? PdfDictionary, depth > 0, direct.containsKey("EF") { current = .attachments }
            let inner: PdfObject = (value as? PdfStream)?.dictionary ?? value
            if let dictionary = inner as? PdfDictionary {
                for (key, item) in dictionary.entries {
                    if Self.backLinks.contains(key) || key == skip { continue }
                    stack.append((item, current, depth + 1))
                }
            } else if let array = inner as? PdfArray {
                for item in array.items { stack.append((item, current, depth + 1)) }
            }
        }
    }

    private func overridden(_ target: PdfObject, _ kind: SpaceKind) -> SpaceKind {
        guard let dictionary = (target as? PdfDictionary) ?? (target as? PdfStream)?.dictionary else { return kind }
        if target is PdfStream && document.name(dictionary, "Subtype") == "Image" { return .images }
        if let type = document.name(dictionary, "Type"), type == "Font" || type == "FontDescriptor" { return .fonts }
        if dictionary.containsKey("EF") { return .attachments }
        return kind
    }
}
