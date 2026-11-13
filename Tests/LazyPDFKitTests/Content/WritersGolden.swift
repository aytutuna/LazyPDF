import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Content/WritersGolden.cs. One line of writers-input.txt is "<writer> <text>"; the
// writer puts the text on a blank page with the script font of the shaping golden, and the output is every object of the
// file with streams decoded. Font programs are only named, since the two engines subset differently.
enum WritersGolden {
    private final class OneFont: FontSource {
        let data: [UInt8]
        init(_ data: [UInt8]) { self.data = data }
        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
    }

    static func run(_ font: [UInt8], _ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let space = line.firstIndex(of: " ")!
            let op = String(line[..<space])
            let text = String(line[line.index(after: space)...]).replacingOccurrences(of: #"\n"#, with: "\n")
            output += "> " + line + "\n"
            output += try dump(try write(op, OneFont(font), text)) + "\n"
        }
        return output
    }

    private static func write(_ op: String, _ fonts: FontSource, _ text: String) throws -> PdfDocument {
        let document = try AnnotationFixtures.blank(1)
        switch op {
        case "freetext":
            _ = try PdfAnnotationWriter(document, fonts).addFreeText(document.pages[0], PdfRect(50, 600, 250, 700), text,
                                                                    font: FreeTextStyle(family: "Script Sans", size: 14))
        case "textbox":
            let session = try PdfEditSession.open(try AnnotationFixtures.blank(1).saveRewrite())
            _ = try PageEditor(session, 0, fonts).addTextBox(PdfRect(50, 600, 250, 700), text, TextBoxStyle(family: "Script Sans", size: 14))
            return try PdfDocument.open(session.current)
        case "edit":
            let edit = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET")
            let result = try PageEditor(edit, 0, fonts).replaceText(try EditKit.find(edit, "world"), text)
            XCTAssertTrue(result.done)
            return try PdfDocument.open(edit.current)
        case "watermark":
            _ = try PdfStamper(document, fonts).addWatermark(WatermarkSpec(text: text, fontFamily: "Script Sans"))
        case "header":
            _ = try PdfStamper(document, fonts).addHeaderFooter(HeaderFooterSpec(
                header: HeaderFooterBand("", text, ""), footer: HeaderFooterBand(text, "", ""), fontFamily: "Script Sans"))
        case "bates":
            _ = try PdfStamper(document, fonts).addHeaderFooter(HeaderFooterSpec(
                footer: HeaderFooterBand("", "{bates}", ""), fontFamily: "Script Sans", bates: BatesSpec(prefix: text, suffix: " " + text, digits: 3)))
        case "redact", "redactrepeat":
            var options = RedactionOptions()
            options.overlayText = text
            options.repeatOverlay = op == "redactrepeat"
            options.fontFamily = "Script Sans"
            let marked = try PdfRedactor(document, fonts).apply([RedactionMark.fromRect(0, PdfRect(100, 690, 300, 720))], options)
            return try PdfDocument.open(marked.bytes)
        case "sign":
            let draw = try PdfFontEmbedder(document, fonts).add("Script Sans", .regular, [text])!
            _ = try SignatureAppearance.draw(document, PdfRect(0, 0, 200, 60), 0, SignatureLook(), text, draw)
        case "field", "multiline", "comb", "combo":
            try field(document, fonts, op, text)
        case "plain":
            return try PdfDocument.open(try PdfFromText.create(text, fonts: fonts, family: "Script Sans").bytes)
        default: break
        }
        return document
    }

    private static func field(_ document: PdfDocument, _ fonts: FontSource, _ op: String, _ text: String) throws {
        let form = PdfForm.read(document, fonts)
        let rect = PdfRect(50, 600, 250, op == "multiline" ? 700 : 630)
        let spec: FieldSpec
        switch op {
        case "multiline": spec = FieldSpec(.text, "f", 0, rect, value: text, flags: .multiline, fontSize: 12)
        case "comb": spec = FieldSpec(.text, "f", 0, rect, value: text, flags: .comb, maxLength: 8, fontSize: 12)
        case "combo": spec = FieldSpec(.comboBox, "f", 0, rect, value: text, options: [FieldOption(text, text)], fontSize: 12)
        default: spec = FieldSpec(.text, "f", 0, rect, value: text, fontSize: 12)
        }
        _ = try form.addField(spec)
    }

    private static func dump(_ document: PdfDocument) throws -> String {
        var lines: [String] = []
        for number in document.objectNumbers {
            let text: String
            switch document.get(number) {
            case let s as PdfStream where s.dictionary.containsKey("Length1"): text = "stream font program"
            case let s as PdfStream: text = "stream \(s.dictionary) | \(Golden.escape(Latin1.string(try document.data(s))))"
            case let value?: text = value.description
            case nil: text = "null"
            }
            lines.append("\(number): \(text)")
        }
        // The subset tag and the annotation name are random; the stream length and whether a short stream is deflated at all depend on the deflate of each engine.
        var dump = lines.joined(separator: "\n")
        for (pattern, template) in [(#"/[A-Z]{6}\+"#, "/AAAAAA+"), (#"/NM \([^)]*\)"#, "/NM (id)"), (#" ?/(Length \d+|Filter /FlateDecode)"#, "")] {
            let regex = try NSRegularExpression(pattern: pattern)
            dump = regex.stringByReplacingMatches(in: dump, range: NSRange(dump.startIndex..., in: dump), withTemplate: template)
        }
        return dump
    }
}
