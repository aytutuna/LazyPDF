import Foundation

// Twin of windows/LazyPDF.Core/Forms/PdfForm.Data.cs: the field values as FDF and CSV, and filling from them.

extension PdfForm {
    // The nesting stays as deep as PdfFdf reads; the rest of a longer name is kept as one part, so the name joins back whole.
    private static let maxFdfParts = 32

    /// The field values as an FDF file (ISO 32000-1 12.7.7), with `PdfFdf.write` or `PdfXfdf.write` to turn it into bytes.
    /// Buttons, signatures and fields marked no-export are left out; a name two fields share is written once. A name with
    /// periods becomes nested fields.
    public func exportFdf(_ fileName: String? = nil) -> FdfFile {
        let fdf = FdfFile()
        fdf.fileName = fileName
        let root = FdfNode("")
        for field in exported() {
            var node = root
            for part in field.name.splitPeriods(Self.maxFdfParts) { node = node.child(part) }
            node.value = fdfValue(field)
        }
        fdf.fields.append(contentsOf: root.children.map { $0.toField() })
        return fdf
    }

    /// Fills the fields the FDF or XFDF file names. Values go through `setValues`, so appearances are drawn and calculations
    /// run.
    @discardableResult
    public func importFdf(_ fdf: FdfFile) throws -> FormFillResult {
        var entries: [(name: String, text: String?, choices: [String]?)] = []
        for (name, value) in fdf.flatFields() {
            let resolved = fdf.resolve(value)
            if let array = resolved as? PdfArray {
                entries.append((name, nil, array.items.compactMap { textOf(fdf.resolve($0)) }))
            } else if let one = resolved, let text = textOf(one) {
                entries.append((name, text, nil))
            }
        }
        return try fill(entries)
    }

    /// The values as a two-line CSV text: the field names, then what they hold. Check boxes and radio groups give their
    /// export value or Off, a list with several choices joins them with "; ".
    public func exportCsv() -> String {
        let listed = exported()
        return FormCsv.write([listed.map { $0.name }, listed.map { csvValue($0) }])
    }

    private func exported() -> [FormField] {
        var seen = Set<[UInt16]>()
        return fields.filter { f in
            f.kind != .pushButton && f.kind != .signature && !f.has(.noExport) && seen.insert(Array(f.name.utf16)).inserted
        }
    }

    private func fdfValue(_ field: FormField) -> PdfObject {
        switch field.kind {
        case .checkBox, .radio:
            guard let value = field.value, value != "Off" else { return PdfName("Off") }
            return PdfName(field.widgets.first { $0.export?.equalsOrdinal(value) == true }?.onState ?? value)
        case .listBox where field.has(.multiSelect):
            return PdfArray(field.selected.map { PdfText.toObject($0) })
        default:
            if field.kind == .comboBox || field.kind == .listBox { return PdfText.toObject(field.selected.first ?? "") }
            return PdfText.toObject(field.value ?? "")
        }
    }

    private func csvValue(_ field: FormField) -> String {
        field.kind == .listBox ? field.selected.joined(separator: "; ") : field.value ?? ""
    }

    private func textOf(_ value: PdfObject?) -> String? {
        switch value {
        case let s as PdfString: return PdfText.decode(s.bytes)
        case let n as PdfName: return n.value
        case let n as PdfNumber: return n.text
        default: return nil
        }
    }

    private final class FdfNode {
        let name: String
        var children: [FdfNode] = []
        var value: PdfObject?

        init(_ name: String) {
            self.name = name
        }

        func child(_ part: String) -> FdfNode {
            if let found = children.first(where: { $0.name.equalsOrdinal(part) }) { return found }
            let made = FdfNode(part)
            children.append(made)
            return made
        }

        func toField() -> FdfField { FdfField(name, value, children.map { $0.toField() }) }
    }
}
