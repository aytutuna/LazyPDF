import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.Flatten.cs: burning the widgets into the pages.

extension PdfForm {
    /// Burns the widgets of the fields (all fields when nil) into their pages' content as the annotation flattener does
    /// (ISO 32000-1 12.5.5), takes the fields out of the form, and removes /AcroForm when none is left. A widget that is
    /// hidden shows nothing and is dropped without a trace. A field whose appearance is missing, or all of them when
    /// /NeedAppearances is set, is drawn first from its value; one that cannot be drawn (no font for its text) is burned as
    /// it is. Returns the number of widgets burned in.
    @discardableResult
    public func flatten(_ fields: [FormField]? = nil) throws -> Int {
        try requireFillable()
        let chosen = fields ?? self.fields
        try regenerateStale(chosen)

        var widgets = Set<ObjectIdentifier>()
        for field in chosen {
            for widget in current(field)?.widgets ?? field.widgets { widgets.insert(ObjectIdentifier(widget.dictionary)) }
        }
        var burned = 0
        for page in document.pages {
            burned += try PdfAnnotationFlattener.flatten(document, page, include: { widgets.contains(ObjectIdentifier($0.dictionary)) })
        }
        for field in chosen {
            for widget in current(field)?.widgets ?? field.widgets { takeFromPages(widget) }
            removeField(current(field) ?? field)
        }

        if self.fields.allSatisfy({ f in chosen.contains { $0.dictionary === f.dictionary } }) {
            let hadXfa = document.hasXfa
            document.catalog.remove("AcroForm")
            xfaRemoved = xfaRemoved || hadXfa
        } else {
            dropXfa()
        }
        refresh()
        return burned
    }

    // Draws the fields whose appearance is missing, or all of them under /NeedAppearances; one that cannot be drawn keeps what it has.
    func regenerateStale(_ fields: [FormField]) throws {
        try requireFillable()
        let stale = needAppearances
        for field in fields {
            if field.kind == .signature { continue }
            if !stale && field.widgets.allSatisfy({ document.dict($0.dictionary, "AP")?["N"] != nil }) { continue }
            do {
                try regenerate([field])
            } catch is InvalidOperationException {
            }
        }
    }

    /// The fields of the document drawn afresh where their appearance is missing or /NeedAppearances is set.
    static func regenerateStale(_ document: PdfDocument) throws {
        let form = read(document)
        try form.regenerateStale(form.fields)
    }
}
