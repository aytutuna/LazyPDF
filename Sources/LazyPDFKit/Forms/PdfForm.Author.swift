import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.Author.cs: adding, moving, removing and renaming fields and widgets.
// The C# ArgumentException is a thrown `ArgumentException` with the C# text, since typed input and a file without a /Rect
// reach it; a name already in use is a thrown InvalidOperationException.

extension PdfForm {
    // Keys that belong to the widget annotation rather than the field when the two are one dictionary.
    private static let widgetKeys = ["Type", "Subtype", "Rect", "F", "P", "MK", "AP", "AS", "BS", "Border", "H", "A", "OC", "StructParent"]
    private static let inheritedKeys = ["FT", "Ff", "V", "DV", "DA", "Q", "MaxLen", "Opt"]

    private static let kindFlags: FieldFlags = [.radio, .pushButton, .combo]

    /// Adds a field and its first widget to the page, with an appearance, and returns it. A name with periods puts the field
    /// under parents of those names, made as needed. A bad name, page or rectangle throws `ArgumentException` and a name
    /// already in use throws `InvalidOperationException`.
    @discardableResult
    public func addField(_ spec: FieldSpec) throws -> FormField {
        try requireFillable()
        let path = try splitName(spec.name)
        try ensureFree(spec.name)
        let page = try openPage(spec.pageIndex)
        if spec.rect.isEmpty { throw ArgumentException(FormText.badRect) }
        let (parentRef, items) = try container(path, spec.name)

        var flags = spec.flags.subtracting(Self.kindFlags)
        switch spec.kind {
        case .radio: flags.formUnion([.radio, .noToggleToOff])
        case .pushButton: flags.formUnion(.pushButton)
        case .comboBox: flags.formUnion(.combo)
        default: break
        }
        if spec.kind == .text && (spec.maxLength <= 0 || flags.contains(.multiline) || flags.contains(.password) || flags.contains(.fileSelect)) {
            flags.remove(.comb)
        }

        let node = PdfDictionary()
        switch spec.kind {
        case .text: node["FT"] = PdfName("Tx")
        case .checkBox, .radio, .pushButton: node["FT"] = PdfName("Btn")
        case .comboBox, .listBox: node["FT"] = PdfName("Ch")
        default: node["FT"] = PdfName("Sig")
        }
        node["T"] = PdfText.toObject(path[path.count - 1])
        if flags != .none { node["Ff"] = PdfNumber(flags.rawValue) }
        if spec.kind != .signature {
            node["DA"] = PdfText.toObject(daString(spec.font, spec.fontSize, spec.textColor))
        }
        if spec.alignment == 1 || spec.alignment == 2 { node["Q"] = PdfNumber(spec.alignment) }
        if spec.kind == .text && spec.maxLength > 0 { node["MaxLen"] = PdfNumber(spec.maxLength) }
        if let options = spec.options, !options.isEmpty, spec.kind == .comboBox || spec.kind == .listBox { node["Opt"] = optionsObject(options) }
        if let tooltip = spec.tooltip, !tooltip.isEmpty { node["TU"] = PdfText.toObject(tooltip) }
        if let dv = spec.defaultValue { node["DV"] = spec.kind == .checkBox || spec.kind == .radio ? PdfName(dv) : PdfText.toObject(dv) }
        if let parentRef { node["Parent"] = parentRef }

        let widget = spec.kind == .radio ? PdfDictionary() : node
        fillWidget(widget, page, spec.rect, spec)
        let nodeRef = try document.add(node)
        var widgetRef = nodeRef
        if widget !== node {
            widget["Parent"] = nodeRef
            widgetRef = try document.add(widget)
            node["Kids"] = PdfArray([widgetRef])
        }
        items.items.append(nodeRef)
        appendAnnotation(page, widgetRef)
        dropXfa()
        refresh()

        guard let created = find(spec.name) else { throw InvalidOperationException(FormText.notAField) }
        try draw(created, spec.exportValue ?? (spec.kind == .radio ? "Choice1" : "Yes"), spec.value)
        guard let added = find(spec.name) else { throw InvalidOperationException(FormText.notAField) }
        return added
    }

    /// Adds another widget to a field: a second place for the same text field, or the next button of a radio group (`export`
    /// is what it stands for). It looks like the field's first widget.
    @discardableResult
    public func addWidget(_ field: FormField, _ pageIndex: Int, _ rect: PdfRect, _ export: String? = nil) throws -> FormWidget {
        try requireFillable()
        guard let fieldReference = field.reference else { throw InvalidOperationException(FormText.notAField) }
        let page = try openPage(pageIndex)
        if rect.isEmpty { throw ArgumentException(FormText.badRect) }
        var target = field
        if target.widgets.count == 1 && target.widgets[0].dictionary === target.dictionary {
            try splitWidget(target)
            guard let split = current(target.dictionary) else { throw InvalidOperationException(FormText.notAField) }
            target = split
        }

        let widget = PdfDictionary()
        widget["Parent"] = fieldReference
        let first = target.widgets.first?.dictionary
        for key in ["MK", "BS", "Border"] {
            if let value = first?[key] { widget[key] = (value as? PdfDictionary)?.copy() ?? value }
        }
        widget["Type"] = PdfName("Annot")
        widget["Subtype"] = PdfName("Widget")
        widget["Rect"] = rect.toArray()
        widget["F"] = PdfNumber(4)
        widget["P"] = page.reference
        let widgetRef = try document.add(widget)
        if let kids = document.array(target.dictionary, "Kids") {
            kids.items.append(widgetRef)
        } else {
            target.dictionary["Kids"] = PdfArray([widgetRef])
        }
        appendAnnotation(page, widgetRef)
        dropXfa()
        refresh()

        guard let now = current(target.dictionary) else { throw InvalidOperationException(FormText.notAField) }
        let state = export ?? (now.kind == .radio ? freeChoice(now) : now.widgets.first?.onState ?? "Yes")
        try draw(now, state, nil)
        guard let added = current(target.dictionary)?.widgets.first(where: { $0.dictionary === widget }) else {
            throw InvalidOperationException(FormText.notAField)
        }
        return added
    }

    /// Moves the widget by the offsets (points, y up) and draws it again.
    public func move(_ widget: FormWidget, _ dx: Double, _ dy: Double) throws {
        try resize(widget, PdfRect(widget.rect.left + dx, widget.rect.bottom + dy, widget.rect.right + dx, widget.rect.top + dy))
    }

    /// Gives the widget a new rectangle and draws its appearance again at that size.
    public func resize(_ widget: FormWidget, _ rect: PdfRect) throws {
        try requireFillable()
        if rect.isEmpty { throw ArgumentException(FormText.badRect) }
        widget.dictionary["Rect"] = rect.toArray()
        dropXfa()
        if let field = fieldOf(widget) { try regenerate([field]) }
    }

    /// Takes one widget out; the field goes with its last one.
    public func remove(_ widget: FormWidget) throws {
        try requireFillable()
        guard let field = fieldOf(widget) else { return }
        if field.widgets.count <= 1 || widget.dictionary === field.dictionary {
            try remove(field)
            return
        }
        takeFromPages(widget)
        if let kids = document.array(field.dictionary, "Kids") {
            let at = kids.items.firstIndex { document.resolve($0) === widget.dictionary }
            kids.items.removeAll { document.resolve($0) === widget.dictionary }
            if let at, field.kind == .radio || field.kind == .checkBox {
                PageCleanup.forgetButton(document, field.dictionary, at, widget.dictionary)
            }
        }
        if let reference = widget.reference { document.delete(reference.number) }
        dropXfa()
        refresh()
    }

    /// Takes the field out with its widgets, and the parents it leaves empty.
    public func remove(_ field: FormField) throws {
        try requireFillable()
        retargetButtons(field.name, nil)
        removeField(field)
        dropXfa()
        refresh()
    }

    func removeField(_ field: FormField) {
        for widget in field.widgets {
            takeFromPages(widget)
            if let reference = widget.reference, widget.dictionary !== field.dictionary { document.delete(reference.number) }
        }
        removeFromCalculation(field.dictionary, field.reference)
        let (parent, taken) = detach(field.dictionary, field.reference)
        freeObject(field.reference ?? taken)
        prune(parent)
    }

    /// Gives the field a new full name; a name with periods moves it under those parents.
    public func rename(_ field: FormField, _ name: String) throws {
        try requireFillable()
        let path = try splitName(name)
        if !name.equalsOrdinal(field.name) { try ensureFree(name) }
        let d = field.dictionary
        var oldParentName = ""
        if let dot = field.name.utf16.lastIndex(of: 0x2E) { oldParentName = String(decoding: Array(field.name.utf16[..<dot]), as: UTF16.self) }
        if !path.dropLast().joined(separator: ".").equalsOrdinal(oldParentName) {
            for key in Self.inheritedKeys where !d.containsKey(key) {
                if let value = inherited(d, ancestors(d), key) { d[key] = value }
            }
            let (parent, taken) = detach(d)
            let (parentRef, items) = try container(path, name)
            guard let listed = field.reference ?? taken else { throw InvalidOperationException(FormText.notAField) }
            items.items.append(listed)
            if let parentRef {
                d["Parent"] = parentRef
            } else {
                d.remove("Parent")
            }
            prune(parent)
        }
        d["T"] = PdfText.toObject(path[path.count - 1])
        retargetButtons(field.name, name)
        dropXfa()
        refresh()
    }

    // Show and Hide actions hold the full name of their target as a string, so they follow a rename and go with a removed field.
    private func retargetButtons(_ name: String, _ renamed: String?) {
        for button in fields where button.kind == .pushButton {
            for widget in button.widgets {
                guard let a = document.dict(widget.dictionary, "A"), document.name(a, "S") == "Hide",
                      PdfText.read(document, a["T"])?.equalsOrdinal(name) == true else { continue }
                if let renamed {
                    a["T"] = PdfText.toObject(renamed)
                } else {
                    widget.dictionary.remove("A")
                }
            }
        }
    }

    /// Sets or clears one of the field's flag bits. The bits that name the kind (radio, push button, combo) cannot be changed.
    public func setFlag(_ field: FormField, _ flag: FieldFlags, _ on: Bool) throws {
        try requireFillable()
        if !flag.intersection(Self.kindFlags).isEmpty { throw ArgumentException("The kind of a field cannot be changed.") }
        let flags = on ? field.flags.union(flag) : field.flags.subtracting(flag)
        store(field.dictionary, "Ff", flags == .none ? nil : PdfNumber(flags.rawValue), PdfNumber(0))
        try regenerate([field])
    }

    public func setTooltip(_ field: FormField, _ tooltip: String?) {
        if let tooltip, !tooltip.isEmpty {
            field.dictionary["TU"] = PdfText.toObject(tooltip)
        } else {
            field.dictionary.remove("TU")
        }
        refresh()
    }

    /// Sets /DV; for a check box or radio group it is the name of the default state.
    public func setDefaultValue(_ field: FormField, _ value: String?) {
        var stored: PdfObject?
        if let value, !value.isEmpty {
            stored = field.kind == .checkBox || field.kind == .radio ? PdfName(value) : PdfText.toObject(value)
        }
        store(field.dictionary, "DV", stored, PdfText.toObject(""))
        refresh()
    }

    /// Replaces the choices of a combo or list box and draws it again. Selected values that are no longer offered stay in /V.
    public func setOptions(_ field: FormField, _ options: [FieldOption]) throws {
        try requireFillable()
        if field.kind != .comboBox && field.kind != .listBox { throw ArgumentException("Only a combo box or list box has options.") }
        field.dictionary["Opt"] = optionsObject(options)
        field.dictionary.remove("I")
        try regenerate([field])
    }

    public func setMaxLength(_ field: FormField, _ length: Int) throws {
        try requireFillable()
        store(field.dictionary, "MaxLen", length > 0 ? PdfNumber(length) : nil, PdfNumber(0))
        try regenerate([field])
    }

    // Removing a key hands the value back to an ancestor that has one, so an empty value is written then.
    private func store(_ d: PdfDictionary, _ key: String, _ value: PdfObject?, _ empty: PdfObject) {
        if let value {
            d[key] = value
        } else if ancestors(d).contains(where: { present($0[key]) != nil }) {
            d[key] = empty
        } else {
            d.remove(key)
        }
    }

    func optionsObject(_ options: [FieldOption]) -> PdfArray {
        PdfArray(options.map { o -> PdfObject in
            o.export == o.display ? PdfText.toObject(o.export) : PdfArray([PdfText.toObject(o.export), PdfText.toObject(o.display)])
        })
    }

    private func splitName(_ name: String) throws -> [String] {
        let path = name.splitPeriods()
        if path.contains(where: { $0.isEmpty }) { throw ArgumentException(FormText.badName) }
        return path
    }

    private func ensureFree(_ name: String) throws {
        if fields.contains(where: { $0.name.equalsOrdinal(name) || $0.name.hasPrefixOrdinal(name + ".") || name.hasPrefixOrdinal($0.name + ".") }) {
            throw InvalidOperationException(FormText.nameTaken(name))
        }
    }

    // PageAt for a call that can carry any page number is refused with a thrown error; `pageAt` is for the tab order, whose page
    // the caller is looking at.
    func openPage(_ index: Int) throws -> PdfPage {
        if index < 0 || index >= document.pages.count { throw ArgumentException(FormText.noPage) }
        return document.pages[index]
    }

    func pageAt(_ index: Int) -> PdfPage {
        precondition(index >= 0 && index < document.pages.count, FormText.noPage)
        return document.pages[index]
    }

    // The array the new field goes in, with the parents on the way made if they are not there yet.
    private func container(_ path: [String], _ fullName: String) throws -> (parentRef: PdfReference?, items: PdfArray) {
        let acro = try ensureAcroForm()
        var items: PdfArray
        if let existing = document.array(acro, "Fields") {
            items = existing
        } else {
            items = PdfArray([])
            acro["Fields"] = items
        }
        var parentRef: PdfReference?
        for i in 0..<(path.count - 1) {
            let at = items.items.firstIndex { item in
                guard let d = document.resolve(item) as? PdfDictionary else { return false }
                return PdfText.read(document, d, "T")?.equalsOrdinal(path[i]) == true
            }
            var node: PdfDictionary
            if let at {
                guard let found = document.resolve(items.items[at]) as? PdfDictionary, document.array(found, "Kids") != nil else {
                    throw InvalidOperationException(FormText.nameTaken(fullName))
                }
                node = found
                if let existing = items.items[at] as? PdfReference {
                    parentRef = existing
                } else {
                    let made = try document.add(node)
                    items.items[at] = made
                    parentRef = made
                }
            } else {
                node = PdfDictionary()
                node["T"] = PdfText.toObject(path[i])
                node["Kids"] = PdfArray([])
                if let parentRef { node["Parent"] = parentRef }
                let made = try document.add(node)
                parentRef = made
                items.items.append(made)
            }
            guard let kids = document.array(node, "Kids") else { throw InvalidOperationException(FormText.nameTaken(fullName)) }
            items = kids
        }
        return (parentRef, items)
    }

    private func fillWidget(_ widget: PdfDictionary, _ page: PdfPage, _ rect: PdfRect, _ spec: FieldSpec) {
        widget["Type"] = PdfName("Annot")
        widget["Subtype"] = PdfName("Widget")
        widget["Rect"] = rect.toArray()
        widget["F"] = PdfNumber(4)
        widget["P"] = page.reference
        let mk = PdfDictionary()
        let turn = spec.rotation % 360
        if turn == 90 || turn == 180 || turn == 270 { mk["R"] = PdfNumber(turn) }
        if let border = spec.borderColor, [1, 3, 4].contains(border.count) { mk["BC"] = numbers(border) }
        if let background = spec.background, [1, 3, 4].contains(background.count) { mk["BG"] = numbers(background) }
        if let caption = spec.caption, !caption.isEmpty { mk["CA"] = PdfText.toObject(caption) }
        if mk.count > 0 { widget["MK"] = mk }
        if spec.borderColor != nil {
            let bs = PdfDictionary()
            bs["Type"] = PdfName("Border")
            bs["W"] = PdfNumber(spec.borderWidth)
            switch spec.borderStyle {
            case .dashed: bs["S"] = PdfName("D")
            case .beveled: bs["S"] = PdfName("B")
            case .inset: bs["S"] = PdfName("I")
            case .underline: bs["S"] = PdfName("U")
            default: bs["S"] = PdfName("S")
            }
            if spec.borderStyle == .dashed { bs["D"] = PdfArray([PdfNumber(3)]) }
            widget["BS"] = bs
        }
    }

    private func numbers(_ values: [Double]) -> PdfArray { PdfArray(values.map { PdfNumber($0) }) }

    private func appendAnnotation(_ page: PdfPage, _ widget: PdfReference) {
        if let annots = document.array(page.dictionary, "Annots") {
            annots.items.append(widget)
        } else {
            page.dictionary["Annots"] = PdfArray([widget])
        }
    }

    // Gives a new field its appearance, and its first value if it has one.
    private func draw(_ field: FormField, _ state: String, _ value: String?) throws {
        if field.kind == .checkBox || field.kind == .radio {
            let appearance = FormAppearance(document)
            for widget in field.widgets where widget.onState == nil {
                try appearance.apply(field, widget, nil, "", onState: state)
                widget.dictionary["AS"] = PdfName("Off")
            }
            refresh()
            if let value, let now = current(field.dictionary), let change = prepare(now, parts(now, value)) { try commit([change]) }
            return
        }
        if let value, field.kind != .signature, let change = prepare(field, parts(field, value)) {
            try commit([change])
        } else {
            try regenerate([field])
        }
    }

    // The widget's keys move to a dictionary of their own, so that the field can have several.
    private func splitWidget(_ field: FormField) throws {
        guard let fieldReference = field.reference else { throw InvalidOperationException(FormText.notAField) }
        let d = field.dictionary
        let widget = PdfDictionary()
        for key in Self.widgetKeys {
            guard let value = d[key] else { continue }
            widget[key] = value
            d.remove(key)
        }
        widget["Parent"] = fieldReference
        let widgetRef = try document.add(widget)
        d["Kids"] = PdfArray([widgetRef])
        for page in document.pages {
            if let annots = document.array(page.dictionary, "Annots") {
                for i in 0..<annots.items.count where document.resolve(annots.items[i]) === d { annots.items[i] = widgetRef }
            }
        }
        refresh()
    }

    // The first ChoiceN that no button of the group has, so that a removal does not make two buttons share a state.
    private func freeChoice(_ group: FormField) -> String {
        let used = Set(group.widgets.compactMap { $0.onState })
        var n = 1
        while used.contains("Choice" + String(n)) { n += 1 }
        return "Choice" + String(n)
    }

    func takeFromPages(_ widget: FormWidget) {
        var pages = Array(document.pages)
        if widget.pageIndex >= 0 && widget.pageIndex < pages.count { pages = [pages[widget.pageIndex]] }
        for page in pages {
            if let annots = document.array(page.dictionary, "Annots") {
                annots.items.removeAll { document.resolve($0) === widget.dictionary }
            }
        }
    }

    // Takes the node out of the array that holds it and gives that array's owner back, with the reference it was listed by.
    // The reference is also matched by number, for a node an earlier step has already freed.
    private func detach(_ node: PdfDictionary, _ known: PdfReference? = nil) -> (parent: PdfDictionary?, taken: PdfReference?) {
        let parent = document.dict(node, "Parent")
        let items = parent != nil ? document.array(parent, "Kids") : document.array(acroForm, "Fields")
        func matches(_ i: PdfObject) -> Bool {
            if document.resolve(i) === node { return true }
            if let known, let r = i as? PdfReference { return r.number == known.number }
            return false
        }
        let taken = items?.items.compactMap { $0 as? PdfReference }.first(where: matches)
        items?.items.removeAll(where: matches)
        return (parent, taken)
    }

    // A parent left without kids goes too, and so on up.
    private func prune(_ start: PdfDictionary?) {
        var node = start
        var depth = 0
        while let current = node, depth < Self.maxDepth, let kids = document.array(current, "Kids"), kids.items.isEmpty {
            removeFromCalculation(current)
            let (up, taken) = detach(current)
            freeObject(taken)
            node = up
            depth += 1
        }
    }

    private func freeObject(_ reference: PdfReference?) {
        if let reference { document.delete(reference.number) }
    }

    private func removeFromCalculation(_ node: PdfDictionary, _ known: PdfReference? = nil) {
        guard let order = document.array(acroForm, "CO") else { return }
        order.items.removeAll { i in
            if document.resolve(i) === node { return true }
            if let known, let r = i as? PdfReference { return r.number == known.number }
            return false
        }
    }

    func ancestors(_ node: PdfDictionary) -> [PdfDictionary] {
        var chain: [PdfDictionary] = []
        var up = document.dict(node, "Parent")
        while let current = up, chain.count < Self.maxDepth, !chain.contains(where: { $0 === current }) {
            chain.insert(current, at: 0)
            up = document.dict(current, "Parent")
        }
        return chain
    }
}
