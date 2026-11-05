import Foundation

// Twin of windows/LazyPDF.Core/Signatures/ChangeFields.cs: fields: what filling one changes, which fields an earlier
// signature locked, and when a new signature field is real.

extension ChangeDetector {
    private static let maxDepth = 32

    func field(_ n: Int, _ node: FieldNode?, _ a: PdfDictionary, _ b: PdfDictionary) {
        guard let node else {
            report(.form, n, allowed: false)
            return
        }
        for key in Self.keys(a, b) {
            if Self.equal(a, b, key) { continue }
            if key == "V" && node.isSignature {
                report(.signature, n, field: node.name, allowed: !node.hasValue && signatureAdded(b) && !isLocked(node))
            } else if ["Type", "Subtype", "Rect", "F", "P"].contains(key) && node.isSignature && !node.hasValue {
                report(.signature, n, field: node.name, allowed: Self.placed(a, b, key) && signatureAdded(b) && !isLocked(node))
            } else if key == "AP" || key == "AS" {
                fieldChange(n, node, filling: !node.hasValue || !node.isSignature)
            } else if key == "V" || key == "M" || key == "I" {
                fieldChange(n, node, filling: true)
            } else if (key == "DA" || key == "TI" || key == "RV") && !node.isSignature {
                fieldChange(n, node, filling: true)
            } else if key != "Lock" || !node.isSignature || node.hasValue {
                report(.form, n, field: node.name, allowed: false)
            }
        }
    }

    // The appearance or value object of a field, or of a comment.
    func part(_ n: Int, _ job: Job, added: Bool) {
        if job.kind == .appearance && job.owner == 0 {
            report(.comment, n, job.page)
        } else if let node = jobsA.fields[job.owner] {
            fieldChange(n, node, filling: !node.hasValue || !node.isSignature)
        } else if added, let fresh = jobsB.fields[job.owner], !Self.isListed(docA.entries[job.owner]) {
            report(.signature, n, job.page, field: fresh.name, allowed: fresh.isSignature && signatureAdded(docB.get(job.owner) as? PdfDictionary))
        } else {
            report(.form, n, job.page, allowed: false)
        }
    }

    func addedField(_ n: Int, _ page: Int) {
        let field = docB.get(n) as? PdfDictionary
        let signature = isSignatureField(field)
        report(signature ? .signature : .form, n, page, field: fieldName(field), allowed: signature && signatureAdded(field))
    }

    private func fieldChange(_ n: Int, _ node: FieldNode, filling: Bool) {
        if node.isSignature {
            report(.signature, n, field: node.name, allowed: filling && signatureAdded(docB.get(node.number) as? PdfDictionary))
            return
        }
        report(.formFill, n, field: node.name, allowed: filling && permits(.formFill) && !isLocked(node) && !readOnly(node) && !pushbutton(node))
    }

    // Signing a field that has no widget gives it one: the keys of an annotation (12.5.2, 12.7.4.5). A field that was
    // a widget when it was signed is on the page, and where it sits is part of what was signed.
    private static func placed(_ a: PdfDictionary, _ b: PdfDictionary, _ key: String) -> Bool {
        switch key {
        case "Type": return a["Type"] == nil && (b["Type"] as? PdfName)?.value == "Annot"
        case "Subtype": return a["Subtype"] == nil && (b["Subtype"] as? PdfName)?.value == "Widget"
        default: return a["Subtype"] == nil
        }
    }

    // The nearest dictionary of the field or its /Parent chain that has the key (12.7.3.1), as the signed revision has it.
    private func holderOf(_ node: FieldNode, _ key: String) -> PdfDictionary? {
        var field = docA.get(node.number) as? PdfDictionary
        var i = 0
        while let current = field, i < Self.maxDepth {
            if current.containsKey(key) { return current }
            field = docA.dict(current, "Parent")
            i += 1
        }
        return nil
    }

    // What the C# gets from (long)flags: a number past the range of a long saturates and NaN is 0.
    private static func bits(_ flags: Double) -> Int {
        if flags.isNaN { return 0 }
        if flags >= 9.2e18 { return Int.max }
        if flags <= -9.2e18 { return Int.min }
        return Int(flags)
    }

    // A field no honest fill changes (bit 1 of /Ff).
    func readOnly(_ node: FieldNode) -> Bool {
        guard let holder = holderOf(node, "Ff") else { return false }
        guard let flags = docA.number(holder, "Ff") else { return true }
        return Self.bits(flags) & 1 != 0
    }

    // A pushbutton has no value to fill (12.7.4.2.2, bit 17 of /Ff): what it draws is fixed.
    private func pushbutton(_ node: FieldNode) -> Bool {
        guard let type = holderOf(node, "FT"), docA.name(type, "FT") == "Btn", let holder = holderOf(node, "Ff"),
              let flags = docA.number(holder, "Ff") else { return false }
        return Self.bits(flags) & (1 << 16) != 0
    }

    // A lock or a read-only field holds how a field is drawn as well as what it says, and a viewer that rebuilds
    // appearances (12.7.2) draws it from the form's defaults.
    private var guarded: Bool {
        if !locks.isEmpty { return true }
        if let known = readOnlyCache { return known }
        let any = jobsA.fields.values.contains { readOnly($0) }
        readOnlyCache = any
        return any
    }

    // Defaults change only for a form nothing guards, or by gaining a font no signed field names in its /DA: that cannot change how one draws.
    func defaultsAllowed(_ grew: Bool) -> Bool { permits(.formFill) && (!guarded || grew) }

    func grew(_ a: PdfDictionary, _ b: PdfDictionary, _ depth: Int) -> Bool {
        for key in Self.keys(a, b) {
            if Self.equal(a, b, key) { continue }
            let grown: Bool
            switch depth {
            case 0: grown = key == "Font" && self.grown(a[key], b[key], 1)
            case 1: grown = !a.containsKey(key) && !daNames().contains(Array(key.utf16))
            default: grown = false
            }
            if !grown { return false }
        }
        return true
    }

    func grown(_ before: PdfObject?, _ after: PdfObject?, _ depth: Int) -> Bool {
        let a = before == nil ? PdfDictionary() : docA.resolve(before) as? PdfDictionary
        guard let a, let b = docB.resolve(after) as? PdfDictionary else { return false }
        return grew(a, b, depth)
    }

    // The font names the default appearance strings of the signed revision use, fields and form alike.
    private func daNames() -> Set<[UInt16]> {
        if let known = daNamesCache { return known }
        var names = Set<[UInt16]>()
        for number in docA.objectNumbers {
            guard let value = docA.get(number) else { continue }
            for dictionary in Self.dictionaries(value) {
                guard let da = PdfText.read(docA, dictionary["DA"]) else { continue }
                names.formUnion(Self.fontNames(da))
            }
        }
        daNamesCache = names
        return names
    }

    // /[^\s/<>\[\]()]+ over the string, each name with its #xx escapes undone.
    private static func fontNames(_ text: String) -> [[UInt16]] {
        let units = Array(text.utf16)
        var names: [[UInt16]] = []
        var i = 0
        while i < units.count {
            if units[i] == 0x2F {
                var j = i + 1
                while j < units.count && !DotNetText.isWhiteSpace(units[j]) && !"/<>[]()".utf16.contains(units[j]) { j += 1 }
                if j > i + 1 {
                    names.append(unescaped(Array(units[i + 1..<j])))
                    i = j
                    continue
                }
            }
            i += 1
        }
        return names
    }

    private static func hexValue(_ unit: UInt16) -> UInt16? {
        switch unit {
        case 0x30...0x39: return unit - 0x30
        case 0x41...0x46: return unit - 0x41 + 10
        case 0x61...0x66: return unit - 0x61 + 10
        default: return nil
        }
    }

    // #[0-9A-Fa-f]{2} becomes the character it spells.
    private static func unescaped(_ name: [UInt16]) -> [UInt16] {
        var result: [UInt16] = []
        var i = 0
        while i < name.count {
            if name[i] == 0x23, i + 2 < name.count, let high = hexValue(name[i + 1]), let low = hexValue(name[i + 2]) {
                result.append(high << 4 | low)
                i += 3
            } else {
                result.append(name[i])
                i += 1
            }
        }
        return result
    }

    private static func dictionaries(_ value: PdfObject) -> [PdfDictionary] {
        var found: [PdfDictionary] = []
        var pending: [PdfObject] = [value]
        while let next = pending.popLast() {
            switch next {
            case let array as PdfArray:
                pending.append(contentsOf: array.items)
            case let dictionary as PdfDictionary:
                found.append(dictionary)
                for (_, item) in dictionary.entries { pending.append(item) }
            case let stream as PdfStream:
                pending.append(stream.dictionary)
            default:
                break
            }
        }
        return found
    }

    private func isSignatureField(_ start: PdfDictionary?) -> Bool {
        var field = start
        var i = 0
        while let current = field, i < Self.maxDepth {
            if let type = docB.name(current, "FT") { return type == "Sig" }
            field = docB.dict(current, "Parent")
            i += 1
        }
        return false
    }

    // The value of a field, which a kid widget may leave to its parent.
    private func valueOf(_ start: PdfDictionary?) -> PdfObject? {
        var field = start
        var i = 0
        while let current = field, i < Self.maxDepth {
            if let value = current["V"] { return value }
            field = docB.dict(current, "Parent")
            i += 1
        }
        return nil
    }

    private func fieldName(_ field: PdfDictionary?) -> String? {
        guard let field else { return nil }
        return PdfText.read(docB, field["T"])
    }

    // A signature is only there when its dictionary is an object of the file with a byte range that closes at a revision;
    // a field that holds anything else is a drawing, whatever its /Type claims. It has to be written by the update, not
    // one the signed revision already held, and to belong to one field.
    private func isSignature(_ value: PdfObject?) -> Bool {
        guard let r = value as? PdfReference, let entry = docB.entries[r.number], entry.kind == .inUse,
              entry.offset >= docA.source.count, signatures.contains(entry.offset) else { return false }
        return references()[r.number] == 1
    }

    private func isTimestamp(_ field: PdfDictionary?) -> Bool {
        guard let v = docB.resolve(valueOf(field)) as? PdfDictionary else { return false }
        return docB.name(v, "Type") == "DocTimeStamp"
    }

    // A signature field that came with a signature and no action: any signature where the level permits signing, and
    // a document time stamp that shows nothing whatever the level, because anyone can have a real time stamp made.
    func signatureAdded(_ field: PdfDictionary?) -> Bool {
        isSignature(valueOf(field)) && quiet(field, area: false) && (permits(.signature) || isTimestamp(field) && quiet(field, area: true))
    }

    // Neither the field nor its widgets, kids or parents, run an action, and with area set have no area to show. The
    // dictionary itself and every parent over it count whether or not a /Kids array lists them.
    private func quiet(_ start: PdfDictionary?, area: Bool) -> Bool {
        var pending: [PdfDictionary] = []
        var field = start
        var i = 0
        while let current = field, i < Self.maxDepth {
            pending.append(current)
            field = docB.dict(current, "Parent")
            i += 1
        }
        var seen = Set<ObjectIdentifier>()
        while let node = pending.popLast() {
            if !seen.insert(ObjectIdentifier(node)).inserted { continue }
            if seen.count > 200_000 || area && Self.hasArea(node) || node.containsKey("A") || node.containsKey("AA") { return false }
            for kid in docB.array(node, "Kids")?.items ?? [] {
                if let child = docB.resolve(kid) as? PdfDictionary { pending.append(child) }
            }
        }
        return true
    }

    // Anything but one /Rect of four numbers that make an empty box counts as an area: a reader may take a value that is no number as 0 or read the other /Rect.
    private static func hasArea(_ node: PdfDictionary) -> Bool {
        let written = node.entries.filter { $0.key == "Rect" }.count
        if written == 0 { return false }
        guard written == 1, let rect = node["Rect"] as? PdfArray, rect.items.count == 4 else { return true }
        var n: [Double] = []
        for item in rect.items {
            guard let number = item as? PdfNumber else { return true }
            n.append(number.value)
        }
        return !PdfRect(n[0], n[1], n[2], n[3]).isEmpty
    }

    // The locks the signed signatures declare (12.7.4.5).
    func readLocks() {
        for (number, node) in jobsA.fields {
            guard node.isSignature, node.hasValue, let field = docA.get(number) as? PdfDictionary else { continue }
            guard let signature = docA.dict(field, "V"), let references = docA.array(signature, "Reference") else { continue }
            for item in references.items {
                guard let reference = docA.resolve(item) as? PdfDictionary, docA.name(reference, "TransformMethod") == "FieldMDP" else { continue }
                guard let parameters = docA.dict(reference, "TransformParams") else { continue }
                let action: FieldLockAction
                switch docA.name(parameters, "Action") {
                case "Include": action = .include
                case "Exclude": action = .exclude
                default: action = .all
                }
                var names = Set<[UInt16]>()
                for entry in docA.array(parameters, "Fields")?.items ?? [] {
                    if let name = PdfText.read(docA, entry) { names.insert(Array(name.utf16)) }
                }
                locks.append((action, names))
            }
        }
    }

    // A name that has fields under it covers them too (12.8.2.4).
    private static func covered(_ list: Set<[UInt16]>, _ name: [UInt16]) -> Bool {
        list.contains { n in
            name == n || (name.count > n.count && name.starts(with: n) && name[n.count] == 0x2E)
        }
    }

    func isLocked(_ node: FieldNode) -> Bool {
        if locks.isEmpty { return false }
        let known: [Int: Set<[UInt16]>]
        if let cached = lockNames {
            known = cached
        } else {
            known = computeLockNames()
            lockNames = known
        }
        guard let names = known[node.number] else { return true }
        return locks.contains { lock in
            switch lock.action {
            case .all: return true
            case .include: return names.contains { Self.covered(lock.names, $0) }
            case .exclude: return names.contains { !Self.covered(lock.names, $0) }
            }
        }
    }

    // Every name a field goes by: the one the /Kids that lead to it spell, the one a reader qualifies it with up its
    // /Parent chain, and those of the fields below it, whose values it hands on (12.7.3.1). A chain that does not end
    // has no names that can be trusted.
    private func computeLockNames() -> [Int: Set<[UInt16]>] {
        var names: [Int: Set<[UInt16]>] = [:]
        for (number, node) in jobsA.fields { names[number] = [Array(node.name.utf16)] }
        var untrusted = Set<Int>()
        for (number, node) in jobsA.fields {
            guard let qualified = qualified(docA.get(number) as? PdfDictionary) else {
                untrusted.insert(number)
                continue
            }
            for up in ancestors(node) + [number] where names[up] != nil {
                names[up]?.formUnion([Array(node.name.utf16), Array(qualified.utf16)])
            }
        }
        for number in untrusted { names[number] = nil }
        return names
    }

    private func qualified(_ start: PdfDictionary?) -> String? {
        var parts: [String] = []
        var field = start
        var i = 0
        while let current = field {
            if i > Self.maxDepth { return nil }
            if let part = PdfText.read(docA, current["T"]) { parts.append(part) }
            i += 1
            field = docA.dict(current, "Parent")
        }
        return parts.reversed().joined(separator: ".")
    }

    private func ancestors(_ node: FieldNode) -> [Int] {
        var found: [Int] = []
        var up = node.parent
        var i = 0
        while up != 0 && i < Self.maxDepth {
            found.append(up)
            up = jobsA.fields[up]?.parent ?? 0
            i += 1
        }
        var field = docA.get(node.number) as? PdfDictionary
        i = 0
        while i < Self.maxDepth, let parent = field?["Parent"] as? PdfReference {
            found.append(parent.number)
            field = docA.get(parent.number) as? PdfDictionary
            i += 1
        }
        return found
    }
}
