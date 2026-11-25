import Foundation

// Twin of windows/LazyPDF.Core/Redaction/RedactionValues.cs: the text of annotations and form fields, which is not page text:
// where finders look and what applying rewrites.

enum RedactionValues {
    static func read(_ document: PdfDocument) -> [(page: Int, annotation: Int, source: RedactionValueSource, text: String)] {
        var found: [(page: Int, annotation: Int, source: RedactionValueSource, text: String)] = []
        var form: PdfForm?
        var seen = Set<ObjectIdentifier>()
        for p in 0..<document.pages.count {
            let annotations = PdfAnnotations.read(document, document.pages[p])
            for (i, a) in annotations.enumerated() {
                if a.type != .widget {
                    if let contents = a.contents, !contents.isEmpty { found.append((p, i, .comment, contents)) }
                    continue
                }
                if form == nil { form = PdfForm.read(document) }
                guard let form, let field = fieldOf(form, a.dictionary), isText(field), seen.insert(ObjectIdentifier(field.dictionary)).inserted,
                      let value = field.value, !value.isEmpty else { continue }
                found.append((p, i, .field, value))
            }
        }
        return found
    }

    static func fieldOf(_ form: PdfForm, _ widget: PdfDictionary) -> FormField? {
        form.fields.first { f in f.widgets.contains { $0.dictionary === widget } }
    }

    static func isText(_ field: FormField) -> Bool {
        field.kind == .text || (field.kind == .comboBox && field.has(.edit))
    }
}
