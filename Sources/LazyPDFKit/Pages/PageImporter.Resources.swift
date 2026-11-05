import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageImporter.Resources.cs: a page's /Resources may list far more than the page draws:
// some writers give every page the resources of the whole file. Copying them all would carry fonts and pictures of pages
// that were left behind, so a copied page keeps the resources whose names its content mentions.

extension PageImporter {
    private static let maxRounds = 64

    private static let named = ["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"]

    func pruned(_ page: PdfPage, _ resources: PdfObject) throws -> PdfObject {
        if same { return resources }
        return try pruned(resources, usedNames(page))
    }

    // The resources of a form that has its own: the same rule, over the names its own content mentions.
    func prunedForm(_ form: PdfStream, _ resources: PdfObject) throws -> PdfObject {
        if same { return resources }
        var used = Set<String>()
        return try pruned(resources, try tryCollectNames(form, &used) ? used : nil)
    }

    private func pruned(_ resources: PdfObject, _ names: Set<String>?) throws -> PdfObject {
        guard let dictionary = source.resolve(resources) as? PdfDictionary, var used = names else { return resources }
        // A form without resources of its own draws with the page's, so what it names counts as used (7.8.3).
        var scanned = Set<ObjectIdentifier>()
        for _ in 0..<Self.maxRounds {
            let pruned = PdfDictionary()
            var removed = false, grew = false
            for (category, value) in dictionary.entries {
                guard Self.named.contains(category), let group = source.resolve(value) as? PdfDictionary else {
                    pruned.add(category, value)
                    continue
                }
                let kept = PdfDictionary()
                for (name, item) in group.entries where used.contains(name) { kept.add(name, item) }
                for (_, item) in kept.entries {
                    switch source.resolve(item) {
                    case let form as PdfStream where category == "XObject" && source.name(form.dictionary, "Subtype") == "Form"
                        && source.dict(form.dictionary, "Resources") == nil:
                        if !scanned.insert(ObjectIdentifier(form)).inserted { break }
                        if try !tryCollectNames(form, &used) { return resources }
                        grew = true
                    case let font as PdfDictionary where category == "Font" && source.name(font, "Subtype") == "Type3"
                        && source.dict(font, "Resources") == nil:
                        return resources
                    default:
                        break
                    }
                }
                removed = removed || kept.count < group.count
                pruned.add(category, kept)
            }
            if !grew { return removed ? pruned : resources }
        }
        return resources
    }

    private func tryCollectNames(_ stream: PdfStream, _ into: inout Set<String>) throws -> Bool {
        do {
            Self.collectNames(try source.data(stream), &into)
            return true
        } catch is PdfReadException {
            return false
        }
    }

    // Every name written in the content, whatever it is used for. Nil when a stream does not decode: then nothing can be left out.
    private func usedNames(_ page: PdfPage) throws -> Set<String>? {
        var used = Set<String>()
        let contents = source.resolve(page.dictionary["Contents"])
        let items: [PdfObject] = (contents as? PdfArray)?.items ?? [contents ?? PdfNull.instance]
        for item in items {
            if let stream = source.resolve(item) as? PdfStream, try !tryCollectNames(stream, &used) { return nil }
        }
        return used
    }

    private static func collectNames(_ content: [UInt8], _ into: inout Set<String>) {
        var i = 0
        while i < content.count {
            if content[i] != 0x2F {
                i += 1
                continue
            }
            var name = String.UnicodeScalarView()
            i += 1
            while i < content.count && !PdfLexer.isWhiteSpace(Int(content[i])) && !PdfLexer.isDelimiter(Int(content[i])) {
                if content[i] == 0x23, i + 2 < content.count, let high = hexValue(content[i + 1]), let low = hexValue(content[i + 2]) {
                    name.append(Unicode.Scalar(UInt8(high * 16 + low)))
                    i += 2
                } else {
                    name.append(Unicode.Scalar(content[i]))
                }
                i += 1
            }
            into.insert(String(name))
        }
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte) - 0x30
        case 0x41...0x46: return Int(byte) - 0x41 + 10
        case 0x61...0x66: return Int(byte) - 0x61 + 10
        default: return nil
        }
    }
}
