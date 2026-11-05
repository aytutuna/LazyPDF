import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.Style.cs: export values, fonts, sizes, colours and button actions. The C#
// ArgumentException of a value the caller got wrong is a thrown `ArgumentException` with the C# text, since typed input reaches
// it; an export or a field name the form does not allow throws InvalidOperationException.

extension PdfForm {
    // Bit 3 of the submit flags (table 237): send the values as an HTML form, which any web server reads.
    private static let submitAsHtml = 4

    func daString(_ font: String, _ size: Double, _ color: [Double]) -> String {
        let op = color.count == 1 ? "g" : color.count == 4 ? "k" : "rg"
        return "/" + font + " " + PdfNumber(size).text + " Tf " + color.map { PdfNumber($0).text }.joined(separator: " ") + " " + op
    }

    /// Makes the button stand for `export`: the name of its "on" appearance state, or its /Opt entry for a radio group that
    /// has them. Another button of the field may not already use it.
    public func setExportValue(_ widget: FormWidget, _ value: String) throws {
        try requireFillable()
        guard let field = fieldOf(widget) else { throw InvalidOperationException(FormText.notAField) }
        if field.kind != .checkBox && field.kind != .radio { throw ArgumentException(FormText.notAButton) }
        let export = FormFunctions.trim(value)
        if export.isEmpty || export == "Off" { throw ArgumentException(FormText.badExport) }
        guard let index = field.widgets.firstIndex(where: { $0.dictionary === widget.dictionary }) else {
            throw InvalidOperationException(FormText.notAField)
        }
        // A check box drawn in several places has one state, which all its widgets share.
        var same = [widget]
        if field.kind == .checkBox, let shared = widget.onState { same = field.widgets.filter { $0.onState == shared } }
        if field.widgets.filter({ w in !same.contains(where: { $0 === w }) }).contains(where: { $0.export?.equalsOrdinal(export) == true || $0.onState?.equalsOrdinal(export) == true }) {
            throw InvalidOperationException(FormText.exportTaken(export))
        }
        if widget.export?.equalsOrdinal(export) == true { return }

        if field.kind == .radio && field.options.count > index {
            var options = field.options
            options[index] = FieldOption(export)
            field.dictionary["Opt"] = optionsObject(options)
        } else if let old = widget.onState {
            for w in same {
                let d = w.dictionary
                for key in ["N", "D"] {
                    if let states = document.dict(document.dict(d, "AP"), key), let state = states[old] {
                        states.remove(old)
                        states[export] = state
                    }
                }
                if document.name(d, "AS") == old { d["AS"] = PdfName(export) }
            }
            for key in ["V", "DV"] {
                if let name = document.resolve(field.dictionary[key]) as? PdfName, name.value == old { field.dictionary[key] = PdfName(export) }
            }
        } else {
            try FormAppearance(document).apply(field, widget, nil, "", onState: export)
            widget.dictionary["AS"] = PdfName("Off")
        }
        dropXfa()
        refresh()
    }

    /// Sets the font of the field's text to a name in /DR /Font or one of the standard names (Helv, TiRo, Cour and their bold
    /// and italic forms) and draws it again.
    public func setFont(_ field: FormField, _ font: String) throws {
        try requireFillable()
        let known = DefaultAppearance.isStandard(font) || document.dict(document.dict(acroForm, "DR"), "Font")?.containsKey(font) == true
        if !known { throw ArgumentException(FormText.unknownFont(font)) }
        try restyle(field, font, nil, nil)
    }

    /// Sets the size of the field's text in points, 0 to fit the text to the field.
    public func setFontSize(_ field: FormField, _ size: Double) throws {
        try requireFillable()
        if !(size >= 0 && size <= 200) { throw ArgumentException(FormText.badSize) }
        try restyle(field, nil, size, nil)
    }

    /// Sets the colour of the field's text, or of the mark of a check box or radio button: 1, 3 or 4 numbers from 0 to 1.
    public func setTextColor(_ field: FormField, _ color: [Double]) throws {
        try requireFillable()
        if ![1, 3, 4].contains(color.count) || !color.allSatisfy({ $0 >= 0 && $0 <= 1 }) { throw ArgumentException(FormText.badColor) }
        try restyle(field, nil, nil, color)
    }

    /// How the field's text is set, with the form's defaults for what its /DA leaves out.
    public func getTextLook(_ field: FormField) -> TextLook {
        let (font, size, color) = DefaultAppearance.parse(field.defaultAppearance)
        return TextLook(font ?? "Helv", size ?? 0, color ?? [0])
    }

    private func restyle(_ field: FormField, _ font: String?, _ size: Double?, _ color: [Double]?) throws {
        let (oldFont, oldSize, oldColor) = DefaultAppearance.parse(field.defaultAppearance)
        field.dictionary["DA"] = PdfText.toObject(daString(font ?? oldFont ?? "Helv", size ?? oldSize ?? 0, color ?? oldColor ?? [0]))
        // A widget with a /DA of its own would keep the old look.
        for widget in field.widgets where widget.dictionary !== field.dictionary { widget.dictionary.remove("DA") }
        refresh()
        try regenerate([current(field) ?? field])
    }

    /// What the push button does: the action of its first widget.
    public func getButtonAction(_ field: FormField) -> ButtonAction {
        let d = field.widgets.first?.dictionary
        guard let a = document.dict(d, "A") else { return ButtonAction(.none) }
        if document.name(a, "S") == "Hide" {
            let target = PdfText.read(document, a["T"]) ?? (document.resolve(a["T"]) as? PdfName)?.value
            return ButtonAction(document.bool(a, "H") == false ? .show : .hide, target)
        }
        switch PdfActions.read(document, a) {
        case let uri as UriAction: return ButtonAction(.openLink, uri.uri)
        case let reset as ResetFormAction where reset.fields.isEmpty: return ButtonAction(.reset)
        case let submit as SubmitFormAction: return ButtonAction(.submit, submit.url)
        default: return ButtonAction(.other)
        }
    }

    /// Gives every widget of the push button the action, or none. Show and Hide name a field of the form.
    public func setButtonAction(_ field: FormField, _ action: ButtonAction) throws {
        try requireFillable()
        if field.kind != .pushButton { throw ArgumentException(FormText.notAPushButton) }
        let target = FormFunctions.trim(action.target ?? "")
        var written: PdfObject?
        switch action.kind {
        case .none:
            written = nil
        case .openLink, .submit:
            if target.isEmpty { throw ArgumentException(FormText.noAddress) }
            let made: PdfAction = action.kind == .openLink ? UriAction(target) : SubmitFormAction(target, Self.submitAsHtml, [])
            written = try PdfActions.toObject(document, made)
        case .reset:
            written = try PdfActions.toObject(document, ResetFormAction(0, []))
        case .show, .hide:
            if find(target) == nil { throw InvalidOperationException(FormText.noSuchField(target)) }
            let hide = PdfDictionary()
            hide["Type"] = PdfName("Action")
            hide["S"] = PdfName("Hide")
            hide["T"] = PdfText.toObject(target)
            hide["H"] = PdfBoolean(action.kind == .hide)
            written = hide
        case .other:
            throw ArgumentException(FormText.otherAction)
        }
        for widget in field.widgets {
            if let written {
                widget.dictionary["A"] = (written as? PdfDictionary)?.copy() ?? written
            } else {
                widget.dictionary.remove("A")
            }
        }
        dropXfa()
        refresh()
    }
}
