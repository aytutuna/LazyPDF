import Foundation

// Twin of windows/LazyPDF.Core/Pages/PageImporter.Annotations.cs: annotations and form fields of the pages being copied.
// Annotations are copied afresh for every page copy, even when the page is copied twice, because a copy of a form field
// must be its own field.

extension PageImporter {
    private static let maxFieldDepth = 32
    private static let maxActionChain = 32
    private static let maxActionNodes = 512
    private static let defaultAppearanceFont = try? NSRegularExpression(pattern: #"/([^\s/<>\[\]()]+)(\s+[-+\d.]+\s+Tf)"#)

    func copyAnnotations(_ page: PdfPage, _ pageRef: PdfReference, _ dict: PdfDictionary) throws {
        guard let annots = read(page.dictionary["Annots"]) as? PdfArray else { return }
        local.removeAll()
        var items: [(ref: PdfReference, dict: PdfDictionary)] = []
        var direct = 0
        for item in annots.items {
            if let reference = item as? PdfReference, let annotation = read(reference) as? PdfDictionary {
                items.append((reference, annotation))
            } else if let inline = item as? PdfDictionary {
                // No number to key it by, so a direct annotation gets a negative one that no object has.
                direct -= 1
                items.append((PdfReference(direct, 0), inline))
            }
        }

        // The form's defaults come first: a font renamed there is renamed in the /DA of every field copied.
        if !same && items.contains(where: { source.name($0.dict, "Subtype") == "Widget" }) { _ = try targetFields() }

        // Popups go second: one stays only with the annotation that owns it.
        var made: [(annotation: PdfDictionary, fresh: PdfDictionary, ref: PdfReference)] = []
        for popups in [false, true] {
            for (numbered, annotation) in items {
                let popup = source.name(annotation, "Subtype") == "Popup"
                if popup != popups || local[numbered.number] != nil { continue }
                if popup {
                    guard let owner = annotation["Parent"] as? PdfReference, local[owner.number] != nil else { continue }
                } else if try isDeadLink(annotation) {
                    continue
                }
                let fresh = PdfDictionary()
                let reference = try target.add(fresh)
                local[numbered.number] = reference
                made.append((annotation, fresh, reference))
            }
        }
        var sources: [ObjectIdentifier: PdfReference] = [:]
        for (numbered, annotation) in items where sources[ObjectIdentifier(annotation)] == nil { sources[ObjectIdentifier(annotation)] = numbered }
        for (annotation, fresh, reference) in made {
            guard let sourceRef = sources[ObjectIdentifier(annotation)] else { continue }
            try fillAnnotation(annotation, fresh, reference, pageRef, sourceRef)
        }
        try resolveFieldActions()
        for (number, reference) in local.entries where number > 0 {
            record(number, reference)
            if keepTags && taggedCopies[number] == nil { taggedCopies[number] = reference }
        }

        var kept: [PdfObject] = []
        var seen = Set<PdfReference>()
        for item in items {
            if let reference = local[item.ref.number], seen.insert(reference).inserted { kept.append(reference) }
        }
        if !kept.isEmpty { dict["Annots"] = PdfArray(kept) }
    }

    private func fillAnnotation(_ annotation: PdfDictionary, _ fresh: PdfDictionary, _ own: PdfReference, _ pageRef: PdfReference,
                                _ sourceRef: PdfReference) throws {
        let widget = source.name(annotation, "Subtype") == "Widget"
        for (key, value) in annotation.entries {
            if annotation[key] !== value { continue }
            let item: PdfObject?
            switch key {
            case "P": item = pageRef
            case "StructParent": item = keepTags ? value : nil
            case "Parent" where widget: item = nil
            case "Popup", "Parent", "IRT": item = (value as? PdfReference).flatMap { local[$0.number] }
            case "Dest": item = try fixDestination(value)
            case "A": item = try fixAction(value)
            case "AA": item = try fixAdditional(value)
            case "DA": item = try fixDefaultAppearance(value)
            default: item = try copy(value)
            }
            if let item, !(item is PdfNull) { fresh.add(key, item) }
        }
        if widget { try attachWidget(annotation, fresh, own, sourceRef) }
    }

    private func isDeadLink(_ annotation: PdfDictionary) throws -> Bool {
        if source.name(annotation, "Subtype") != "Link" { return false }
        if annotation.containsKey("Dest"), try fixDestination(annotation["Dest"]) == nil { return true }
        if let action = read(annotation["A"]) as? PdfDictionary, source.name(action, "S") == "GoTo" { return try fixDestination(action["D"]) == nil }
        return false
    }

    private func fixAction(_ value: PdfObject, _ depth: Int = 0) throws -> PdfObject? {
        if depth == 0 { actionNodes = 0 }
        guard let action = read(value) as? PdfDictionary, depth <= Self.maxActionChain else { return nil }
        actionNodes += 1
        if actionNodes > Self.maxActionNodes { return nil }
        let type = source.name(action, "S")
        let fieldAction = !same && (type == "SubmitForm" || type == "ResetForm" || type == "Hide")
        let made = PdfDictionary()
        for (key, item) in action.entries {
            if action[key] !== item { continue }
            let result: PdfObject?
            switch key {
            case "D" where type == "GoTo": result = try fixDestination(item)
            case "Next": result = try fixNext(item, depth)
            case "Fields" where fieldAction, "T" where fieldAction: result = nil
            default: result = try copy(item)
            }
            guard let result, !(result is PdfNull) else {
                if key == "D" && type == "GoTo" { return nil }
                continue
            }
            made.add(key, result)
        }
        if fieldAction { fieldActions.append((action, made)) }
        return made
    }

    private func fixNext(_ value: PdfObject, _ depth: Int) throws -> PdfObject? {
        if let list = read(value) as? PdfArray {
            let kept = try list.items.prefix(Self.maxActionChain).compactMap { try fixAction($0, depth + 1) }
            return kept.isEmpty ? nil : PdfArray(kept)
        }
        return try fixAction(value, depth + 1)
    }

    private func fixAdditional(_ value: PdfObject) throws -> PdfObject? {
        guard let triggers = read(value) as? PdfDictionary else { return nil }
        let made = PdfDictionary()
        for (key, item) in triggers.entries where triggers[key] === item {
            if let action = try fixAction(item) { made.add(key, action) }
        }
        return made
    }

    // Fields an action names are set once the fields of the page are copied: those that did not come across drop out of the list.
    private func resolveFieldActions() throws {
        for (original, made) in fieldActions {
            let key = source.name(original, "S") == "Hide" ? "T" : "Fields"
            guard let named = original[key] else { continue }
            let items = (source.resolve(named) as? PdfArray)?.items ?? [named]
            var kept: [PdfObject] = []
            for item in items {
                if let reference = item as? PdfReference {
                    if let field = fields[reference.number] {
                        kept.append(field.ref)
                    } else if let found = local[reference.number] {
                        kept.append(found)
                    }
                } else if item is PdfString {
                    kept.append(try copy(item))
                }
            }
            made[key] = PdfArray(kept)
        }
        fieldActions.removeAll()
    }

    /// The destination for the copy: an explicit one pointing at a page that came across, a named one looked up in the
    /// source and made explicit. Nil when it points at a page that did not.
    private func fixDestination(_ value: PdfObject?) throws -> PdfObject? {
        guard let value else { return nil }
        if same { return try copy(value) }
        var resolved = read(value)
        if resolved is PdfName || resolved is PdfString {
            if names == nil { names = DestContext(source) }
            resolved = source.resolve(names.flatMap { PageDestinations.lookup(source, $0, value) })
        }
        if let named = resolved as? PdfDictionary { resolved = source.resolve(named["D"]) }
        guard let array = resolved as? PdfArray, let first = array.items.first else { return nil }
        if let page = first as? PdfReference, newPages[page.number] == nil { return nil }
        return try copy(array)
    }

    private func attachWidget(_ widget: PdfDictionary, _ fresh: PdfDictionary, _ own: PdfReference, _ sourceRef: PdfReference) throws {
        if let parentRef = widget["Parent"] as? PdfReference, let parentSource = read(parentRef) as? PdfDictionary {
            let parent = try fieldNode(parentRef, parentSource, 1)
            fresh["Parent"] = parent.ref
            parent.kids.items.append(own)
            let position = source.array(parentSource, "Kids")?.items.firstIndex { ($0 as? PdfReference)?.number == sourceRef.number } ?? -1
            groups[ObjectIdentifier(parent.kids)]?.positions.append(position)
        } else if fresh.containsKey("T") || fresh.containsKey("FT") {
            try addRoot(own, fresh)
        }
        dropSignature(widget, fresh)
    }

    // A field above the widgets, made once per import and holding only the widgets that came across.
    private func fieldNode(_ reference: PdfReference, _ node: PdfDictionary, _ depth: Int) throws -> (ref: PdfReference, kids: PdfArray) {
        if let known = fields[reference.number] { return known }
        let fresh = PdfDictionary()
        let kids = PdfArray([])
        let own = try target.add(fresh)
        fields[reference.number] = (own, kids)
        for (key, value) in node.entries {
            if key == "Kids" || key == "Parent" || node[key] !== value { continue }
            let item: PdfObject?
            switch key {
            case "AA": item = try fixAdditional(value)
            case "DA": item = try fixDefaultAppearance(value)
            default: item = try copy(value)
            }
            if let item, !(item is PdfNull) { fresh.add(key, item) }
        }
        fresh["Kids"] = kids
        let group = FieldCopy(node, fresh)
        groups[ObjectIdentifier(kids)] = group
        groupOrder.append(group)
        record(reference.number, own)
        dropSignature(node, fresh)
        if let up = node["Parent"] as? PdfReference, depth < Self.maxFieldDepth, let upNode = read(up) as? PdfDictionary {
            let parent = try fieldNode(up, upNode, depth + 1)
            fresh["Parent"] = parent.ref
            parent.kids.items.append(own)
        } else {
            try addRoot(own, fresh)
        }
        return (own, kids)
    }

    // What a copied signature field signed is not in the copy; the field keeps its look and loses the signature.
    private func dropSignature(_ original: PdfDictionary, _ fresh: PdfDictionary) {
        var node: PdfDictionary? = original
        var depth = 0
        while let current = node, depth < Self.maxFieldDepth {
            if let type = source.name(current, "FT") {
                if type == "Sig" { fresh.remove("V") }
                return
            }
            node = source.dict(current, "Parent")
            depth += 1
        }
    }

    private func addRoot(_ reference: PdfReference, _ root: PdfDictionary) throws {
        let fields = try targetFields()
        var taken = rootNames ?? rootNamesOf(fields)
        if let name = root["T"] as? PdfString {
            var bytes = name.bytes
            var n = 2
            while taken.contains(Latin1.string(bytes)) {
                bytes = Self.suffixed(name.bytes, n)
                n += 1
            }
            name.bytes = bytes
            taken.insert(Latin1.string(bytes))
        }
        rootNames = taken
        if !same, let form = source.dict(source.catalog, "AcroForm") {
            for key in ["DA", "Q"] {
                guard !root.containsKey(key), let inherited = form[key] else { continue }
                if key == "DA" {
                    root[key] = try fixDefaultAppearance(inherited)
                } else {
                    root[key] = try copy(inherited)
                }
            }
        }
        fields.items.append(reference)
    }

    private func rootNamesOf(_ fields: PdfArray) -> Set<String> {
        Set(fields.items.compactMap { (target.resolve($0) as? PdfDictionary)?["T"] as? PdfString }.map { Latin1.string($0.bytes) })
    }

    // Names are text strings: the suffix is written in the encoding the name has.
    private static func suffixed(_ name: [UInt8], _ n: Int) -> [UInt8] {
        let suffix = Array("_\(n)".utf8)
        let utf16 = name.count >= 2 && name[0] == 0xFE && name[1] == 0xFF
        return name + (utf16 ? suffix.flatMap { [0, $0] } : suffix)
    }

    private func targetFields() throws -> PdfArray {
        let form: PdfDictionary
        if let existing = target.dict(target.catalog, "AcroForm") {
            form = existing
        } else {
            form = PdfDictionary()
            target.catalog["AcroForm"] = form
        }
        let fields: PdfArray
        if let existing = target.array(form, "Fields") {
            fields = existing
        } else {
            fields = PdfArray([])
            form["Fields"] = fields
        }
        if !formMerged && !same {
            formMerged = true
            try mergeDefaults(form)
        }
        return fields
    }

    // The fields' default resources come along so that a field's /DA finds its font; a name the target has is not replaced.
    private func mergeDefaults(_ form: PdfDictionary) throws {
        guard let original = source.dict(source.catalog, "AcroForm") else { return }
        if source.bool(original, "NeedAppearances") == true { form["NeedAppearances"] = PdfBoolean(true) }
        guard let resources = source.dict(original, "DR") else { return }
        let into: PdfDictionary
        if let existing = target.dict(form, "DR") {
            into = existing
        } else {
            into = PdfDictionary()
            form["DR"] = into
        }
        for (category, value) in resources.entries {
            guard let named = source.resolve(value) as? PdfDictionary else { continue }
            let group: PdfDictionary
            if let existing = target.dict(into, category) {
                group = existing
            } else {
                group = PdfDictionary()
                into[category] = group
            }
            for (name, item) in named.entries {
                if !group.containsKey(name) {
                    group.add(name, try copy(item))
                } else if category == "Font" && !sameFont(named[name], group[name]) {
                    // The copied fields name this font in their /DA, so it has to come across under a name of its own.
                    var fresh = name
                    var n = 2
                    while group.containsKey(fresh) {
                        fresh = "\(name)_\(n)"
                        n += 1
                    }
                    group.add(fresh, try copy(item))
                    fontRenames[name] = fresh
                }
            }
        }
    }

    private func sameFont(_ original: PdfObject?, _ other: PdfObject?) -> Bool {
        guard let a = source.resolve(original) as? PdfDictionary, let b = target.resolve(other) as? PdfDictionary else { return false }
        return a.description == b.description
    }

    private func fixDefaultAppearance(_ value: PdfObject) throws -> PdfObject {
        guard !fontRenames.isEmpty, let da = PdfText.read(source, value), let regex = Self.defaultAppearanceFont else { return try copy(value) }
        let text = NSString(string: da)
        var result = ""
        var last = 0
        for match in regex.matches(in: da, range: NSRange(location: 0, length: text.length)) {
            result += text.substring(with: NSRange(location: last, length: match.range.location - last))
            if let renamed = fontRenames[text.substring(with: match.range(at: 1))] {
                result += "/" + renamed + text.substring(with: match.range(at: 2))
            } else {
                result += text.substring(with: match.range)
            }
            last = match.range.location + match.range.length
        }
        result += text.substring(from: last)
        return PdfText.toObject(result)
    }

    private func record(_ sourceNumber: Int, _ made: PdfReference) {
        if copies[sourceNumber]?.contains(made) != true { copies[sourceNumber, default: []].append(made) }
    }

    // Calculation order (12.7.6.2): the copies of the fields the source lists follow what the target lists.
    func carryOrder() {
        if let form = source.dict(source.catalog, "AcroForm"), let order = source.array(form, "CO"),
           let into = target.dict(target.catalog, "AcroForm") {
            let added = order.items.compactMap { $0 as? PdfReference }.flatMap { copies[$0.number] ?? [] }
            if !added.isEmpty {
                var list = target.array(into, "CO")
                if list == nil {
                    list = PdfArray([])
                    into["CO"] = list
                }
                list?.items.append(contentsOf: added)
            }
        }
        copies.removeAll()
    }

    // A group that lost some of its buttons keeps the export values of the ones that came, and a value naming a button that
    // stayed behind is Off (the rule of PageCleanup.forgetButton).
    func trimGroups() throws {
        for group in groupOrder {
            guard let all = source.array(group.original, "Kids"), !group.positions.isEmpty, group.positions.count < all.items.count,
                  !group.positions.contains(-1), inheritedButton(group.original) else { continue }
            if let options = source.array(group.original, "Opt") {
                group.made["Opt"] = PdfArray(try group.positions.filter { $0 < options.items.count }.map { try copy(options.items[$0]) })
            }
            let states = group.positions.filter { $0 < all.items.count }.compactMap {
                source.dict(source.dict(source.resolve(all.items[$0]) as? PdfDictionary, "AP"), "N")
            }
            if let value = group.made["V"] as? PdfName, value.value != "Off", !states.isEmpty,
               !states.contains(where: { $0.containsKey(value.value) }) {
                group.made["V"] = PdfName("Off")
            }
        }
        groupOrder.removeAll()
        groups.removeAll()
    }

    private func inheritedButton(_ original: PdfDictionary) -> Bool {
        var field: PdfDictionary? = original
        var depth = 0
        while let current = field, depth < Self.maxFieldDepth {
            if let type = source.name(current, "FT") { return type == "Btn" }
            field = source.dict(current, "Parent")
            depth += 1
        }
        return false
    }
}
