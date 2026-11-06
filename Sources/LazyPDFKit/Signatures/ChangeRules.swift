import Foundation

// Twin of windows/LazyPDF.Core/Signatures/ChangeRules.cs: what each kind of object may change into (ISO 32000-1
// 12.8.2.2 and 12.7.4.5). Each table names the keys that may differ at a level; a key it does not name is not allowed.

extension ChangeDetector {
    func catalog(_ n: Int, _ a: PdfDictionary, _ b: PdfDictionary) {
        for key in Self.keys(a, b) {
            if Self.equal(a, b, key) { continue }
            switch key {
            case "DSS", "Extensions", "Version":
                report(.validationData, n)
            case "AcroForm":
                catalogForm(n, a[key], b[key])
            case "Metadata":
                report(.metadata, n)
            case "Perms":
                report(.signature, n, allowed: false)
            default:
                report(.pageStructure, n, allowed: false)
            }
        }
    }

    // The same indirect object is compared when it comes up on its own; another generation reads as nothing.
    private func catalogForm(_ n: Int, _ before: PdfObject?, _ after: PdfObject?) {
        if let r1 = before as? PdfReference, let r2 = after as? PdfReference, r1.number == r2.number {
            report(.form, n, allowed: false)
            return
        }
        let a = before == nil ? PdfDictionary() : docA.resolve(before) as? PdfDictionary
        let b = docB.resolve(after) as? PdfDictionary
        if let a, let b { acroForm(n, a, b) } else { report(.form, n, allowed: false) }
    }

    func acroForm(_ n: Int, _ a: PdfDictionary, _ b: PdfDictionary) {
        for key in Self.keys(a, b) {
            if Self.equal(a, b, key) { continue }
            if key == "Fields", let ra = a[key] as? PdfReference, let rb = b[key] as? PdfReference, ra.number == rb.number {
                report(.form, n, allowed: false)
                continue
            }
            switch key {
            case "Fields":
                fieldsDiff((docA.resolve(a[key]) as? PdfArray)?.items ?? [], (docB.resolve(b[key]) as? PdfArray)?.items ?? [])
            case "SigFlags":
                report(.signature, n, allowed: true)
            case "DR":
                report(.formFill, n, allowed: defaultsAllowed(grown(a[key], b[key], 0)))
            case "NeedAppearances", "DA", "Q":
                report(.formFill, n, allowed: defaultsAllowed(false))
            default:
                report(.form, n, allowed: false)
            }
        }
    }

    func page(_ n: Int, _ index: Int, _ a: PdfDictionary, _ b: PdfDictionary) {
        for key in Self.keys(a, b) {
            if Self.equal(a, b, key) { continue }
            if key != "Annots" {
                report(key == "Contents" || key == "Resources" ? .pageContent : .pageStructure, n, index, allowed: false)
                continue
            }
            let x = a[key], y = b[key]
            var sameReference = false
            if let ra = x as? PdfReference, let rb = y as? PdfReference { sameReference = ra.number == rb.number }
            if sameReference || !Self.isAnnots(x) || !Self.isAnnots(y) {
                report(.pageStructure, n, index, allowed: false)
            } else {
                annotsDiff((docA.resolve(x) as? PdfArray)?.items ?? [], (docB.resolve(y) as? PdfArray)?.items ?? [], index)
            }
        }
    }

    // Null, a reference or an array.
    private static func isAnnots(_ value: PdfObject?) -> Bool {
        value == nil || value is PdfReference || value is PdfArray
    }

    // What a comment may say, show and where it sits (12.5.2, 12.5.6), and no action, destination, layer or tag; it may
    // not become another kind of annotation.
    private static let commentKeys: Set<String> = [
        "Type", "Contents", "M", "NM", "C", "CA", "F", "Rect", "Border", "BS", "BE", "RD", "T", "Subj", "RC", "CreationDate",
        "IC", "QuadPoints", "L", "LE", "LL", "LLE", "LLO", "CP", "Cap", "CO", "Measure", "CL", "IT", "Name", "Open", "State", "StateModel",
        "Vertices", "InkList", "DA", "DS", "Q", "Popup", "Parent", "IRT", "RT", "P", "AP", "AS", "Sy", "RO", "OverlayText", "Repeat",
    ]

    func comment(_ n: Int, _ page: Int, _ a: PdfDictionary, _ b: PdfDictionary) {
        for key in Self.keys(a, b) where !Self.equal(a, b, key) {
            report(.comment, n, page, allowed: Self.commentKeys.contains(key) && permits(.comment))
        }
    }

    func addedComment(_ n: Int, _ page: Int) {
        report(.comment, n, page, allowed: Self.isComment(docB.get(n)) && permits(.comment))
    }

    private static func isComment(_ value: PdfObject?) -> Bool {
        guard let comment = value as? PdfDictionary else { return false }
        return comment.entries.allSatisfy { $0.key == "Subtype" || commentKeys.contains($0.key) }
    }

    // The dates and producer a tool rewrites whenever it saves are not what the signer read, so they pass at every level.
    func information(_ n: Int, _ a: PdfDictionary?, _ b: PdfDictionary?) {
        var stamp = false
        if let a, let b { stamp = Self.keys(a, b).allSatisfy { Self.equal(a, b, $0) || $0 == "ModDate" || $0 == "Producer" } }
        report(.metadata, n, allowed: stamp || permits(.metadata))
    }

    func packet(_ n: Int, _ a: PdfStream, _ b: PdfStream) throws {
        var stamp = Self.keys(a.dictionary, b.dictionary).allSatisfy {
            $0 == "Length" || $0 == "Filter" || $0 == "DecodeParms" || Self.equal(a.dictionary, b.dictionary, $0)
        }
        if stamp { stamp = Self.withoutStamps(try docA.data(a)) == Self.withoutStamps(try docB.data(b)) }
        report(.metadata, n, allowed: stamp || permits(.metadata))
    }

    // The same dates and producer in the XMP packet, which a tool that rewrites them in the information rewrites here too: the
    // C# removes /\s(?:xmp:(?:ModifyDate|MetadataDate)|pdf:Producer)="[^"]*"|<(xmp:(?:ModifyDate|MetadataDate)|pdf:Producer)>[^<]*<\/\1>/
    // from the text of the packet. It is read here by hand, left to right as the expression is, so that a packet cannot
    // make a search that takes longer than the packet is long.
    private static let stampNames: [[UInt8]] = ["xmp:ModifyDate", "xmp:MetadataDate", "pdf:Producer"].map { Array($0.utf8) }

    private static func withoutStamps(_ bytes: [UInt8]) -> [UInt8] {
        let lastQuote = bytes.lastIndex(of: UInt8(ascii: "\"")) ?? -1
        let lastOpen = bytes.lastIndex(of: UInt8(ascii: "<")) ?? -1
        var output: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if let end = stampEnd(bytes, i, lastQuote, lastOpen) {
                i = end
            } else {
                output.append(bytes[i])
                i += 1
            }
        }
        return output
    }

    private static func isRegexSpace(_ b: UInt8) -> Bool {
        (b >= 9 && b <= 13) || b == 32 || b == 0x85 || b == 0xA0
    }

    private static func has(_ bytes: [UInt8], _ at: Int, _ word: [UInt8]) -> Bool {
        at >= 0 && at + word.count <= bytes.count && bytes[at..<at + word.count].elementsEqual(word)
    }

    private static func stampEnd(_ bytes: [UInt8], _ i: Int, _ lastQuote: Int, _ lastOpen: Int) -> Int? {
        if isRegexSpace(bytes[i]) {
            for name in stampNames where has(bytes, i + 1, name) {
                let j = i + 1 + name.count
                guard has(bytes, j, [UInt8(ascii: "="), UInt8(ascii: "\"")]), lastQuote >= j + 2 else { return nil }
                var k = j + 2
                while bytes[k] != UInt8(ascii: "\"") { k += 1 }
                return k + 1
            }
        } else if bytes[i] == UInt8(ascii: "<") {
            for name in stampNames where has(bytes, i + 1, name) {
                let j = i + 1 + name.count
                guard has(bytes, j, [UInt8(ascii: ">")]), lastOpen > j else { return nil }
                var k = j + 1
                while bytes[k] != UInt8(ascii: "<") { k += 1 }
                let close = [UInt8(ascii: "<"), UInt8(ascii: "/")] + name + [UInt8(ascii: ">")]
                return has(bytes, k, close) ? k + close.count : nil
            }
        }
        return nil
    }

    // Validation data only grows into the shapes ETSI EN 319 142-1 5.4 gives it: /DSS and /VRI with the entries named, lists and streams of data.
    func validation(_ n: Int, _ depth: Int, _ before: PdfObject, _ after: PdfObject) {
        if let a = before as? PdfDictionary, let b = after as? PdfDictionary, depth < 3 {
            for key in Self.keys(a, b) {
                let known: Bool
                switch depth {
                case 0: known = ["Type", "VRI", "Certs", "OCSPs", "CRLs"].contains(key)
                case 1: known = Jobs.isHex40(key)
                default: known = ["Type", "Cert", "OCSP", "CRL", "TU", "TS"].contains(key)
                }
                if !Self.equal(a, b, key) { report(known ? .validationData : .other, n, allowed: known) }
            }
        } else if depth < 3 {
            report(.other, n, allowed: false)
        } else {
            report(.validationData, n)
        }
    }

    // The references of a list, each once, in the order they stand.
    private static func references(_ items: [PdfObject]) -> (ordered: [PdfReference], members: Set<PdfReference>) {
        var members = Set<PdfReference>()
        var ordered: [PdfReference] = []
        for case let r as PdfReference in items where members.insert(r).inserted { ordered.append(r) }
        return (ordered, members)
    }

    func fieldsDiff(_ before: [PdfObject], _ after: [PdfObject]) {
        let old = Self.references(before), kept = Self.references(after)
        for r in old.ordered where !kept.members.contains(r) {
            report(.form, r.number, field: jobsA.fields[r.number]?.name, allowed: false)
        }
        // A field the update makes is judged as a new object; one that was there already cannot be listed again.
        for r in kept.ordered where !old.members.contains(r) && Self.isListed(docA.entries[r.number]) {
            report(.form, r.number, allowed: false)
        }
        if Self.directChanged(before, after) || Self.reordered(before, after) { report(.form, 0, allowed: false) }
    }

    func annotsDiff(_ before: [PdfObject], _ after: [PdfObject], _ page: Int) {
        let old = Self.references(before), kept = Self.references(after)
        for r in old.ordered where !kept.members.contains(r) {
            let widget = Self.isWidget(docA, r)
            report(widget ? .form : .comment, r.number, page, allowed: !widget && permits(.comment))
        }
        for r in kept.ordered where !old.members.contains(r) && Self.isListed(docA.entries[r.number]) {
            let placed = placing(r.number)
            report(placed ? .signature : .form, r.number, page, allowed: placed)
        }
        // A direct entry has no identity, so one that differs is a removed annotation and a new one, judged as an indirect one is.
        for item in Self.unmatched(before, after) { directAnnotation(docA, item, page, added: false) }
        for item in Self.unmatched(after, before) { directAnnotation(docB, item, page, added: true) }
        let widgets = (before + after).contains { ($0 as? PdfDictionary).map { docA.name($0, "Subtype") == "Widget" } ?? false }
        if Self.reordered(before, after) { report(widgets ? .form : .comment, 0, page, allowed: !widgets && permits(.comment)) }
    }

    private func directAnnotation(_ document: PdfDocument, _ item: PdfObject, _ page: Int, added: Bool) {
        let widget = (item as? PdfDictionary).map { document.name($0, "Subtype") == "Widget" } ?? false
        let known = !added || Self.isComment(item)
        report(widget ? .form : .comment, 0, page, allowed: !widget && known && permits(.comment))
    }

    // The direct entries of the first list that the second does not hold as often.
    private static func unmatched(_ list: [PdfObject], _ other: [PdfObject]) -> [PdfObject] {
        var rest = other.filter { !($0 is PdfReference) }.map { text($0) }
        var found: [PdfObject] = []
        for item in list where !(item is PdfReference) {
            let key = text(item)
            if let at = rest.firstIndex(of: key) {
                rest.remove(at: at)
            } else {
                found.append(item)
            }
        }
        return found
    }

    // An unsigned signature field with no widget, listed on a page by the update that signs it.
    private func placing(_ number: Int) -> Bool {
        guard let node = jobsA.fields[number], node.isSignature, !node.hasValue, let was = docA.get(number) as? PdfDictionary,
              docA.name(was, "Subtype") != "Widget", let field = docB.get(number) as? PdfDictionary else { return false }
        return signatureAdded(field) && !isLocked(node)
    }

    private static func isWidget(_ document: PdfDocument, _ r: PdfReference) -> Bool {
        guard let d = document.get(r.number) as? PdfDictionary else { return false }
        return document.name(d, "Subtype") == "Widget"
    }

    private static func directChanged(_ before: [PdfObject], _ after: [PdfObject]) -> Bool {
        before.filter { !($0 is PdfReference) }.map { text($0) } != after.filter { !($0 is PdfReference) }.map { text($0) }
    }

    // The order of the entries both lists hold, direct ones among them, is the stacking of annotations and the tab order of fields.
    private static func reordered(_ before: [PdfObject], _ after: [PdfObject]) -> Bool {
        let old = before.map { text($0) }, new = after.map { text($0) }
        let oldSet = Set(old), newSet = Set(new)
        return old.filter { newSet.contains($0) } != new.filter { oldSet.contains($0) }
    }

    // Compared with every entry of a repeated key, which the dictionary's lookup leaves out but another parser may read.
    static func equal(_ a: PdfDictionary, _ b: PdfDictionary, _ key: String) -> Bool {
        values(a, key) == values(b, key)
    }

    private static func values(_ dictionary: PdfDictionary, _ key: String) -> String {
        dictionary.entries.filter { $0.key == key }.map { text($0.value) }.joined(separator: " ")
    }

    static func text(_ value: PdfObject?) -> String {
        var text = ""
        write(value, &text)
        return text
    }

    private static func write(_ value: PdfObject?, _ text: inout String) {
        switch value {
        case let dictionary as PdfDictionary:
            text.append("<<")
            for (key, item) in dictionary.entries {
                text.append(PdfName(key).description)
                text.append(" ")
                write(item, &text)
                text.append(" ")
            }
            text.append(">>")
        case let array as PdfArray:
            text.append("[")
            for item in array.items {
                write(item, &text)
                text.append(" ")
            }
            text.append("]")
        case let other?:
            text.append(other.description)
        case nil:
            break
        }
    }

    static func keys(_ a: PdfDictionary, _ b: PdfDictionary) -> [String] {
        var seen = Set<String>()
        return (a.entries + b.entries).map { $0.key }.filter { seen.insert($0).inserted }
    }
}
