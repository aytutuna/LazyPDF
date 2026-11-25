import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.Fill.cs: setting values, resetting and drawing the appearances again.

extension PdfForm {
    private static let trueWords = ["yes", "on", "true", "1", "x", "checked"]

    /// One field's new state: the values to store (a check box or radio group: the state name or "Off").
    final class Change {
        let field: FormField
        let values: [String]
        var font: FormFont?

        init(_ field: FormField, _ values: [String]) {
            self.field = field
            self.values = values
        }
    }

    /// Sets the field called `name` and every field sharing the name. Text is stored as given (cut at /MaxLen); a combo box
    /// takes an export value or its display text; a check box takes an export value, or yes/no words for on and off; a
    /// radio group takes an export value or "Off"; a list with several choices takes them separated by ";". The
    /// appearances are drawn again and the calculation order runs. Throws `InvalidOperationException` when no font can
    /// draw the text and `PdfReadException` for a dynamic XFA form.
    @discardableResult
    public func setValue(_ name: String, _ value: String?) throws -> FormFillResult {
        try setValues([(name, value)])
    }

    /// Sets many fields at once; Turkish text that needs an added font shares one font for the batch.
    @discardableResult
    public func setValues(_ values: [(String, String?)]) throws -> FormFillResult {
        try fill(values.map { (name: $0.0, text: $0.1, choices: nil as [String]?) })
    }

    /// Sets a list box or combo box to several choices (export values or display texts).
    @discardableResult
    public func setChoices(_ name: String, _ choices: [String]) throws -> FormFillResult {
        try fill([(name: name, text: nil, choices: choices)])
    }

    func fill(_ entries: [(name: String, text: String?, choices: [String]?)]) throws -> FormFillResult {
        try requireFillable()
        undrawn = []
        var unknown: [String] = []
        var rejected: [String] = []
        var plan: [Change] = []
        for (name, text, choices) in entries {
            let matches = findAll(name)
            if matches.isEmpty {
                unknown.append(name)
                continue
            }
            for field in matches {
                if let change = prepare(field, choices ?? parts(field, text)) {
                    plan.append(change)
                } else {
                    rejected.append(name)
                }
            }
        }
        try commit(plan)
        let calculation = try recalculate()
        var seen = Set<[UInt16]>()
        let distinct = rejected.filter { seen.insert(Array($0.utf16)).inserted }
        return FormFillResult(plan.count, unknown, distinct, calculation.changed, calculation.notRun,
                               String(String.UnicodeScalarView(undrawn.sorted().compactMap { Unicode.Scalar(UInt32($0)) })))
    }

    /// Puts the named field (all fields when nil) back to its /DV, or to empty without one, and runs the calculation order.
    /// Buttons and signatures are left alone. Returns the number of fields reset.
    @discardableResult
    public func reset(_ name: String? = nil) throws -> Int {
        try requireFillable()
        var plan: [Change] = []
        for field in name.map({ findAll($0) }) ?? fields {
            if field.kind == .pushButton || field.kind == .signature { continue }
            let defaults: [String]
            if field.kind == .listBox || field.kind == .comboBox {
                defaults = defaultChoices(field)
            } else {
                defaults = field.defaultValue.map { [$0] } ?? []
            }
            if let change = prepare(field, defaults, reset: true) { plan.append(change) }
        }
        try commit(plan)
        try recalculate()
        return plan.count
    }

    /// Takes the signature out of a signed signature field, with the field's appearance, and leaves the field empty to sign
    /// again. A certification (/Perms /DocMDP) that rests on that signature goes too. Throws `InvalidOperationException` when
    /// the field is not signed. The signed revision stays in the file's history.
    public func clearSignature(_ field: FormField) throws {
        try requireFillable()
        guard field.isSigned else { throw InvalidOperationException(FormText.notSigned) }
        if let perms = document.dict(document.catalog, "Perms"),
           let docMdp = document.resolve(perms["DocMDP"]), docMdp === document.resolve(field.dictionary["V"]) {
            perms.remove("DocMDP")
            if perms.count == 0 { document.catalog.remove("Perms") }
        }
        field.dictionary.remove("V")
        field.dictionary.remove("AP")
        for widget in field.widgets { widget.dictionary.remove("AP") }
    }

    /// Draws the appearances of the fields again from their values: after the form's maker set /NeedAppearances, or after
    /// changing a field's look by hand.
    public func regenerate(_ fields: [FormField]? = nil) throws {
        try requireFillable()
        let chosen = (fields ?? self.fields).filter { $0.kind != .signature }
        let needs = fontNeeds(chosen.map { ($0, valuesOf($0)) })
        let resolved = try resolveFonts(needs)
        let refreshed = chosen.map { ($0, resolved[fontKey($0)]) }
        for (field, font) in refreshed {
            if let font, font.replaced { setFontName(field, font.font.name) }
        }
        refresh()
        for (old, font) in refreshed {
            if let field = current(old) { try redraw(field, font?.font) }
        }
        dropXfa()
    }

    func parts(_ field: FormField, _ text: String?) -> [String] {
        guard let text else { return [] }
        if field.kind == .listBox && field.has(.multiSelect) {
            return text.split(separator: ";", omittingEmptySubsequences: false).map { FormFunctions.trim(String($0)) }.filter { !$0.isEmpty }
        }
        return [text]
    }

    private func defaultChoices(_ field: FormField) -> [String] {
        let dv = document.resolve(field.dictionary["DV"])
        if dv is PdfArray { return strings(dv) }
        return field.defaultValue.map { [$0] } ?? []
    }

    private func valuesOf(_ field: FormField) -> [String] {
        if field.kind == .listBox || field.kind == .comboBox { return field.selected }
        return field.value.map { [$0] } ?? []
    }

    func prepare(_ field: FormField, _ values: [String], reset: Bool = false) -> Change? {
        var first = values.first ?? ""
        switch field.kind {
        case .text:
            if field.maxLength > 0 && first.unicodeScalars.count > field.maxLength {
                first = String(String.UnicodeScalarView(first.unicodeScalars.prefix(field.maxLength)))
            }
            return Change(field, first.isEmpty ? [] : [first])
        case .comboBox:
            let stored: String
            if field.options.contains(where: { $0.export.equalsOrdinal(first) }) {
                stored = first
            } else {
                stored = field.options.first { $0.display.equalsOrdinal(first) }?.export ?? first
            }
            if !reset && !first.isEmpty && !field.has(.edit) && field.options.allSatisfy({ !$0.export.equalsOrdinal(stored) }) { return nil }
            return Change(field, stored.isEmpty ? [] : [stored])
        case .listBox:
            var chosen: [String] = []
            for v in values {
                if let export = field.options.first(where: { $0.export.equalsOrdinal(v) })?.export ?? field.options.first(where: { $0.display.equalsOrdinal(v) })?.export,
                   !chosen.containsOrdinal(export) {
                    chosen.append(export)
                }
            }
            if chosen.isEmpty && values.contains(where: { !$0.isEmpty }) && !reset { return nil }
            if !field.has(.multiSelect) { chosen = Array(chosen.prefix(1)) }
            return Change(field, chosen)
        case .checkBox, .radio:
            if let state = stateFor(field, first, reset) { return Change(field, [state]) }
            return nil
        default:
            return nil
        }
    }

    // The appearance state a value stands for, or nil when the field has no such button.
    private func stateFor(_ field: FormField, _ value: String, _ reset: Bool) -> String? {
        if value.isEmpty || value == "Off" { return "Off" }
        for i in 0..<field.widgets.count {
            let w = field.widgets[i]
            if value == w.export || value == w.onState || value == stateName(field, i) { return stateName(field, i) }
        }
        if reset || field.kind != .checkBox { return reset ? "Off" : nil }
        let word = value.lowercased()
        if Self.trueWords.contains(word) { return field.widgets.isEmpty ? "Yes" : stateName(field, 0) }
        return word == "no" || word == "off" || word == "false" || word == "0" ? "Off" : nil
    }

    func stateName(_ field: FormField, _ index: Int) -> String {
        let w = field.widgets[index]
        return w.onState ?? w.export ?? (field.kind == .radio ? String(index) : "Yes")
    }

    func commit(_ plan: [Change]) throws {
        if plan.isEmpty { return }
        let needs = fontNeeds(plan.map { ($0.field, $0.values) })
        let resolved = try resolveFonts(needs)
        for change in plan { change.font = resolved[fontKey(change.field)]?.font }

        for change in plan {
            try setStored(change)
            if let font = change.font, resolved[fontKey(change.field)]?.replaced == true { setFontName(change.field, font.name) }
        }
        refresh()
        for change in plan {
            if let field = current(change.field), field.kind != .checkBox && field.kind != .radio { try redraw(field, change.font) }
        }
        dropXfa()
    }

    func current(_ old: FormField) -> FormField? { current(old.dictionary) }

    private func setStored(_ change: Change) throws {
        let field = change.field
        let d = field.dictionary
        switch field.kind {
        case .text, .comboBox:
            if let value = change.values.first { d["V"] = PdfText.toObject(value) } else { clear(d) }
            d.remove("RV")
            if field.kind == .comboBox { d.remove("I") }
        case .listBox:
            if let value = change.values.first {
                if field.has(.multiSelect) {
                    d["V"] = PdfArray(change.values.map { PdfText.toObject($0) })
                } else {
                    d["V"] = PdfText.toObject(value)
                }
                var indexes: [PdfObject] = []
                for (i, option) in field.options.enumerated() where change.values.containsOrdinal(option.export) { indexes.append(PdfNumber(i)) }
                d["I"] = PdfArray(indexes)
            } else {
                clear(d)
                d.remove("I")
            }
        default:
            if let state = change.values.first { try setButtons(field, state) }
        }
    }

    private func setButtons(_ field: FormField, _ state: String) throws {
        field.dictionary["V"] = PdfName(state)
        let look = FormAppearance(document)
        for i in 0..<field.widgets.count {
            let w = field.widgets[i]
            let own = stateName(field, i)
            if !hasState(w, own) { try look.apply(field, w, nil, "", onState: own) }
            w.dictionary["AS"] = PdfName(state == own ? own : "Off")
        }
    }

    private func hasState(_ widget: FormWidget, _ state: String) -> Bool {
        guard let states = document.dict(document.dict(widget.dictionary, "AP"), "N") else { return false }
        return states.containsKey(state) && states.containsKey("Off")
    }

    private func clear(_ d: PdfDictionary) {
        d.remove("V")
        var up = document.dict(d, "Parent")
        var depth = 0
        while let parent = up, depth < 64 {
            if parent.containsKey("V") {
                d["V"] = PdfString(bytes: [], isHex: false)
                return
            }
            depth += 1
            up = document.dict(parent, "Parent")
        }
    }

    private func redraw(_ field: FormField, _ font: FormFont?) throws {
        let appearance = FormAppearance(document)
        let (display, color) = displayOf(field)
        for i in 0..<field.widgets.count {
            let w = field.widgets[i]
            if field.kind == .checkBox || field.kind == .radio {
                let own = stateName(field, i)
                try appearance.apply(field, w, nil, "", onState: own)
                w.dictionary["AS"] = PdfName(field.isChecked && field.value == (w.export ?? own) ? own : "Off")
            } else {
                try appearance.apply(field, w, try widgetFont(field, w, font, display), display, color)
            }
        }
    }

    // A widget with a /DA of its own is set in the font that names, which can differ from its field's.
    private func widgetFont(_ field: FormField, _ widget: FormWidget, _ font: FormFont?, _ display: String) throws -> FormFont? {
        var own: String?
        if let da = PdfText.read(document, widget.dictionary, "DA") { own = DefaultAppearance.parse(da).font }
        guard let own, own != fontKey(field), own != font?.name else { return font }
        let texts = field.kind == .listBox ? field.options.map { $0.display } : [display]
        guard let (resolved, replaced) = try resolveFonts(FontNeeds(own, texts))[own] else { return font }
        if replaced { setFontName(widget.dictionary, PdfText.read(document, widget.dictionary, "DA"), resolved.name) }
        return resolved
    }

    // What a text field shows: its value through the format script, if it has one of the built-in ones.
    func displayOf(_ field: FormField) -> (text: String, color: [Double]?) {
        var raw = field.value ?? ""
        if field.kind == .comboBox { raw = field.options.first { $0.export.equalsOrdinal(field.value ?? "") }?.display ?? field.value ?? "" }
        if field.kind == .text || field.kind == .comboBox, let calls = FormScripts.callsOf(self, field, "F") {
            for call in calls {
                if let formatted = FormFunctions.format(call, raw) { return (formatted.text, formatted.color) }
            }
        }
        return (raw, nil)
    }

    private func fontKey(_ field: FormField) -> String { DefaultAppearance.parse(field.defaultAppearance).font ?? "Helv" }

    /// The text each font name has to show, in the order the names first come.
    struct FontNeeds {
        private(set) var names: [String] = []
        private var byName: [String: [String]] = [:]

        init() {}

        init(_ name: String, _ list: [String]) {
            names = [name]
            byName[name] = list
        }

        func texts(for name: String) -> [String] { byName[name] ?? [] }

        mutating func add(_ name: String, _ list: [String]) {
            if byName[name] == nil {
                names.append(name)
                byName[name] = []
            }
            byName[name]?.append(contentsOf: list)
        }
    }

    private func fontNeeds(_ items: [(FormField, [String])]) -> FontNeeds {
        var needs = FontNeeds()
        for (field, values) in items {
            if field.kind == .checkBox || field.kind == .radio || field.kind == .signature { continue }
            let key = fontKey(field)
            switch field.kind {
            case .listBox:
                needs.add(key, field.options.map { $0.display })
            case .pushButton:
                let mk = document.dict(field.widgets.first?.dictionary, "MK")
                needs.add(key, PdfText.read(document, mk, "CA").map { [$0] } ?? [])
            case .comboBox:
                var shown = ""
                if let v = values.first { shown = field.options.first { $0.export.equalsOrdinal(v) }?.display ?? v }
                needs.add(key, [formatText(field, shown)])
            default:
                needs.add(key, field.has(.password) ? [] : [formatText(field, values.first ?? "")])
            }
        }
        return needs
    }

    private func formatText(_ field: FormField, _ raw: String) -> String {
        if let calls = FormScripts.callsOf(self, field, "F") {
            for call in calls {
                if let formatted = FormFunctions.format(call, raw) { return formatted.text }
            }
        }
        return raw
    }

    // Each font name the fields use, kept if it shows all their text, else replaced by one added font for the whole group.
    private func resolveFonts(_ needs: FontNeeds) throws -> [String: (font: FormFont, replaced: Bool)] {
        var result: [String: (font: FormFont, replaced: Bool)] = [:]
        let resources = try ensureResources()
        for name in needs.names {
            let texts = needs.texts(for: name)
            let current = try FormFont.fromResource(document, name, resources)
            // A kept simple font would show right-to-left text in logical order, so it goes to an added, shaped font.
            if let current, texts.allSatisfy({ current.canShow($0) && !Scripts.needsBidi($0) }) {
                result[name] = (current, false)
                continue
            }
            let (family, style) = current == nil ? known(name) : FormFont.familyOf(document, resources, name)
            let embedder = PdfFontEmbedder(document, fonts)
            let added: PdfDrawFont
            if let first = try embedder.addCovering(family, style, texts) {
                added = first
            } else if let second = try embedder.add("Helvetica", style, texts) {
                added = second
            } else {
                throw InvalidOperationException(FormText.noFont)
            }
            undrawn.formUnion(added.missing)
            // A name already taken (a Type0 subset that fromResource cannot read) keeps its font.
            if current == nil, !added.isEmbedded, let table = document.dict(resources, "Font"), !table.containsKey(name) {
                table[name] = added.reference
                result[name] = (FormFont.fromAdded(name, added), false)
            } else {
                let fresh = ContentResources.add(document, resources, "Font", added.reference, "LzF")
                result[name] = (FormFont.fromAdded(fresh, added), true)
            }
        }
        return result
    }

    private func known(_ name: String) -> (family: String, style: FontStyles) {
        let format = DefaultAppearance.formatOf(name, TextFormat.default)
        var style = FontStyles.regular
        if format.bold { style.insert(.bold) }
        if format.italic { style.insert(.italic) }
        return (format.family, style)
    }

    func setFontName(_ field: FormField, _ name: String) { setFontName(field.dictionary, field.defaultAppearance, name) }

    func setFontName(_ holder: PdfDictionary, _ current: String?, _ name: String) {
        let da = current ?? "/Helv 0 Tf 0 g"
        var updated = da
        if let regex = try? NSRegularExpression(pattern: "/[^\\s/<>\\[\\]()]+(\\s+[-+\\d.]+\\s+Tf)") {
            let template = "/" + NSRegularExpression.escapedTemplate(for: name) + "$1"
            updated = regex.stringByReplacingMatches(in: da, range: NSRange(da.startIndex..., in: da), withTemplate: template)
        }
        if updated == da && !da.contains("Tf") { updated = "/" + name + " 0 Tf " + da }
        holder["DA"] = PdfText.toObject(updated)
    }

    func ensureAcroForm() throws -> PdfDictionary {
        if let existing = acroForm { return existing }
        let acro = PdfDictionary()
        acro["Fields"] = PdfArray([])
        acro["DA"] = PdfText.toObject("/Helv 0 Tf 0 g")
        document.catalog["AcroForm"] = try document.add(acro)
        return acro
    }

    func ensureResources() throws -> PdfDictionary {
        let acro = try ensureAcroForm()
        let resources: PdfDictionary
        if let existing = document.dict(acro, "DR") {
            resources = existing
        } else {
            resources = PdfDictionary()
            acro["DR"] = resources
        }
        if document.dict(resources, "Font") == nil { resources["Font"] = PdfDictionary() }
        return resources
    }

    func requireFillable() throws {
        if xfa == .dynamic { throw PdfReadException(.unsupported, FormText.dynamicXfa) }
    }

    // A static XFA form keeps its own copy of the data, which a viewer shows in place of the AcroForm.
    func dropXfa() {
        guard document.hasXfa, let acro = acroForm else { return }
        acro.remove("XFA")
        document.catalog.remove("NeedsRendering")
        xfaRemoved = true
    }
}
