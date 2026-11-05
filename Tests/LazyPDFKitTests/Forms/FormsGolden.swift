import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Forms/FormsGolden.cs. One line of input is "<op> <words>" (the format is at the top of
// forms-input.txt): script parsing, the AF format, check and calculate functions, number and CSV reading, a form filled,
// reset, built, restyled, flattened and exported, and the blanks found on a page. Streams are shown decoded, because the
// deflate of the two sides is not the same one. Dates without a year are left out of the input: they would read the clock.
enum FormsGolden {
    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? line
            let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
            output += "> \(line)\n"
            for result in try self.op(op, rest) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        do {
            switch op {
            case "parse": return parse(latin(rest))
            case "format": return format(latin(rest))
            case "check": return check(latin(rest))
            case "number": return [FormFunctions.parseNumber(latin(rest)).map { FormFunctions.numberText($0) } ?? "null"]
            case "calc": return try calc(latin(rest))
            case "csv": return csv(latin(rest))
            case "fill": return try fill(latin(rest))
            case "reset": return try reset()
            case "author": return try author()
            case "style": return try style()
            case "flatten": return try flatten()
            case "export": return try export()
            case "detect": return try detect(latin(rest))
            default: return ["unknown op \(op)"]
            }
        } catch let failure as InvalidOperationException {
            return ["refused \(Golden.escape(failure.message))"]
        }
    }

    private static func latin(_ rest: String) -> String { Latin1.string(Golden.unescape(rest)) }

    private static func show(_ text: String?) -> String { text.map { Golden.escape($0) } ?? "-" }

    private static func n(_ value: Double) -> String { PdfNumber(value).text }

    private static func numbers(_ values: [Double]?) -> String { values.map { "[" + $0.map { n($0) }.joined(separator: ",") + "]" } ?? "-" }

    private static func arg(_ value: FormArg) -> String {
        switch value {
        case .null: return "null"
        case .number(let d): return "n" + FormFunctions.numberText(d)
        case .text(let s): return "s" + show(s)
        case .flag(let b): return b ? "true" : "false"
        case .list(let list): return "[" + list.map { arg($0) }.joined(separator: ", ") + "]"
        }
    }

    private static func parse(_ source: String) -> [String] {
        guard let calls = FormScriptParser.parse(source) else { return ["null"] }
        return calls.map { $0.name + "(" + $0.args.map { arg($0) }.joined(separator: ", ") + ")" }
    }

    private static func callOf(_ source: String) -> FormCall? { FormScriptParser.parse(source)?.first }

    private static func split(_ rest: String) -> (head: String, tail: String) {
        guard let bar = rest.firstIndex(of: "|") else { return (rest, "") }
        return (String(rest[..<bar]), String(rest[rest.index(after: bar)...]))
    }

    private static func format(_ rest: String) -> [String] {
        let (source, value) = split(rest)
        guard let call = callOf(source) else { return ["no call"] }
        guard let formatted = FormFunctions.format(call, value) else { return ["null"] }
        return [show(formatted.text) + " " + numbers(formatted.color)]
    }

    private static func check(_ rest: String) -> [String] {
        let (source, value) = split(rest)
        guard let call = callOf(source) else { return ["no call"] }
        return [show(FormFunctions.check(call, value) ?? "ok")]
    }

    private static func calc(_ rest: String) throws -> [String] {
        let (function, text) = split(rest)
        let values = text.isEmpty ? [] : text.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        let names = values.indices.map { String(UnicodeScalar(UInt8(97 + $0))) }
        let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
        guard let call = callOf("AFSimple_Calculate(\"\(function)\", new Array(\(list)))") else { return ["no call"] }
        return [show(FormFunctions.calculate(call) { name in [names.firstIndex(of: name).map { values[$0] }] } ?? "null")]
    }

    private static func csv(_ text: String) -> [String] {
        let rows = FormCsv.read(text)
        var lines = rows.map { "[" + $0.map { show($0) }.joined(separator: " | ") + "]" }
        lines.append("again " + show(FormCsv.write(rows)))
        return lines
    }

    private static func kindName(_ kind: FieldKind) -> String {
        switch kind {
        case .text: return "Text"
        case .checkBox: return "CheckBox"
        case .radio: return "Radio"
        case .pushButton: return "PushButton"
        case .comboBox: return "ComboBox"
        case .listBox: return "ListBox"
        case .signature: return "Signature"
        }
    }

    private static func values(_ array: PdfArray?) -> [Double]? {
        array.map { $0.items.map { ($0 as? PdfNumber)?.value ?? 0 } }
    }

    private static func streamLine(_ document: PdfDocument, _ stream: PdfStream) throws -> String {
        "bbox=\(numbers(values(document.array(stream.dictionary, "BBox")))) matrix=\(numbers(values(document.array(stream.dictionary, "Matrix")))) | \(Golden.escape(try document.data(stream)))"
    }

    private static func dump(_ form: PdfForm, _ only: String? = nil) throws -> [String] {
        let document = form.document
        var lines: [String] = []
        for field in form.fields where only == nil || field.name == only {
            let ti = document.integer(field.dictionary, "TI").map { String($0) } ?? "-"
            lines.append("field \(show(field.name)) \(kindName(field.kind)) ff=\(field.flags.rawValue) value=\(show(field.value)) selected=[\(field.selected.map { show($0) }.joined(separator: ","))] da=\(show(field.defaultAppearance)) "
                + "max=\(field.maxLength) q=\(field.alignment) ti=\(ti) i=\(numbers(values(document.array(field.dictionary, "I"))))")
            for widget in field.widgets {
                let rect = numbers([widget.rect.left, widget.rect.bottom, widget.rect.right, widget.rect.top])
                lines.append("  widget rect=\(rect) page=\(widget.pageIndex) as=\(document.name(widget.dictionary, "AS") ?? "-") on=\(widget.onState ?? "-") export=\(widget.export ?? "-")")
                let normal = document.resolve(document.dict(widget.dictionary, "AP")?["N"])
                if let stream = normal as? PdfStream {
                    lines.append("    ap " + (try streamLine(document, stream)))
                } else if let states = normal as? PdfDictionary {
                    for entry in states.entries {
                        if let s = document.resolve(entry.value) as? PdfStream { lines.append("    ap \(entry.key) " + (try streamLine(document, s))) }
                    }
                }
            }
        }
        return lines
    }

    private static func fill(_ rest: String) throws -> [String] {
        let parts = rest.split(separator: "\t", omittingEmptySubsequences: false).map { String($0) }
        let form = PdfForm.read(try FormFixtures.open())
        let value = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let result = try form.setValue(parts[0], value)
        return ["result filled=\(result.filled) unknown=[\(result.unknownFields.joined(separator: ","))] rejected=[\(result.rejected.joined(separator: ","))] calculated=\(result.calculated)"]
            + (try dump(form, parts[0]))
    }

    private static func filled() throws -> PdfForm {
        let form = PdfForm.read(try FormFixtures.open())
        try form.setValues([("name", "Ada Lovelace"), ("agree", "Yes"), ("choice", "b"), ("city", "Izmir"), ("langs", "English; German"), ("code", "123")])
        return form
    }

    private static func reset() throws -> [String] {
        let form = try filled()
        let count = try form.reset()
        return ["reset \(count)"] + (try dump(form))
    }

    private static func author() throws -> [String] {
        let form = PdfForm.read(try AnnotationFixtures.blank())
        var y = 700.0
        func next() -> PdfRect {
            y -= 40
            return PdfRect(50, y, 250, y + 30)
        }

        try form.addField(FieldSpec(.text, "t", 0, next(), value: "one two three four five six seven eight nine ten", flags: .multiline, borderStyle: .dashed, alignment: 1))
        try form.addField(FieldSpec(.text, "comb", 0, next(), value: "123", flags: .comb, maxLength: 8, alignment: 2))
        try form.addField(FieldSpec(.text, "pw", 0, next(), value: "secret", flags: .password, background: [1, 1, 0.8], borderWidth: 2, borderStyle: .beveled))
        try form.addField(FieldSpec(.text, "turned", 0, PdfRect(50, 100, 80, 250), value: "sideways", fontSize: 10, textColor: [1, 0, 0], borderStyle: .underline, rotation: 90))
        try form.addField(FieldSpec(.checkBox, "c", 0, next(), value: "On", caption: "8", exportValue: "On"))
        try form.addField(FieldSpec(.checkBox, "diamond", 0, next(), value: "Yes", borderStyle: .inset, caption: "u"))
        try form.addField(FieldSpec(.checkBox, "star", 0, next(), value: "Yes", background: [0.9], caption: "H"))
        try form.addField(FieldSpec(.checkBox, "dingbat", 0, next(), value: "Yes", caption: "3"))
        try form.addField(FieldSpec(.radio, "r", 0, next(), value: "one", exportValue: "one"))
        try form.addWidget(try XCTUnwrap(form.find("r")), 0, PdfRect(300, 100, 314, 114), "two")
        try form.addField(FieldSpec(.pushButton, "go", 0, next(), background: [0.8], borderStyle: .beveled, caption: "Send"))
        try form.addField(FieldSpec(.comboBox, "combo", 0, next(), value: "Bee", defaultValue: "a", options: [FieldOption("a"), FieldOption("b", "Bee")]))
        try form.addField(FieldSpec(.listBox, "list", 0, next(), value: "x; z", options: [FieldOption("x"), FieldOption("y"), FieldOption("z")], flags: .multiSelect))
        try form.addField(FieldSpec(.signature, "sig", 0, next()))
        try form.addField(FieldSpec(.text, "group.child", 0, next(), value: "nested", tooltip: "tip"))
        return try dump(form)
    }

    private static func style() throws -> [String] {
        let form = PdfForm.read(try FormFixtures.open())
        try form.setValues([("name", "Ada"), ("agree", "Yes")])
        try form.setFont(try XCTUnwrap(form.find("name")), "TiRo")
        try form.setFontSize(try XCTUnwrap(form.find("name")), 18)
        try form.setTextColor(try XCTUnwrap(form.find("name")), [1, 0, 0])
        try form.setTextColor(try XCTUnwrap(form.find("agree")), [0.2, 0.4, 0.6])
        try form.setExportValue(try XCTUnwrap(form.find("agree")).widgets[0], "Accepted")
        return try dump(form, "name") + dump(form, "agree")
    }

    private static func flatten() throws -> [String] {
        let form = try filled()
        let burned = try form.flatten()
        let page = form.document.pages[0]
        let annots = form.document.array(page.dictionary, "Annots").map { String($0.items.count) } ?? "-"
        return ["burned \(burned) fields \(form.fields.count) form \(form.acroForm == nil ? "none" : "kept") annots \(annots)", "page " + Golden.escape(page.contents())]
    }

    private static func export() throws -> [String] {
        let form = try filled()
        return ["fdf " + Golden.escape(try PdfFdf.write(form.exportFdf("form.pdf"))), "csv " + show(form.exportCsv())]
    }

    private static func detect(_ content: String) throws -> [String] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /DA (/Helv 0 Tf 0 g)>>>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots []>>")
        pdf.stream(4, "", content)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>")
        let found = FieldDetector.detect(try PdfDocument.open(pdf.finish()), 0)
        let lines = found.map { p in
            "\(kindName(p.kind)) \(numbers([p.rect.left, p.rect.bottom, p.rect.right, p.rect.top])) name=\(show(p.name)) label=\(show(p.label)) cells=\(p.cells) multiline=\(p.multiline ? "true" : "false")"
        }
        return lines.isEmpty ? ["none"] : lines
    }
}
