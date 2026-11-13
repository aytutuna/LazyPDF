import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Standards/StandardsGolden.cs. One line of input is "<op> <words>" (the format is at the top of
// standards-input.txt): what the validator finds in a file for a level, what the converter does to it, the XMP packet and the sRGB
// profile byte for byte. The files are made here from the names in the input, with no font file; the converter is given none. A
// converted file is shown as every object of it, streams decoded (a long one with control bytes in it by its length) and without /Length and the Flate filter,
// because the deflate of the two sides is not the same one. The texts are English whatever the machine's language is.
enum StandardsGolden {
    private static let day = DateTimeOffset(2026, 3, 9, 14, 5, 7, offsetMinutes: 180)

    static func run(_ input: String) throws -> String {
        try L10n.english {
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
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        let words = rest.components(separatedBy: " ")
        switch op {
        case "check": return try check(level(words[0]), words[1])
        case "convert": return try convert(level(words[0]), words[1])
        case "packet": return [packet(level(words[0]), words[1] == "true")]
        case "strip": return [strip(rest)]
        case "profile": return [PdfASrgb.srgbProfile.map { String(format: "%02x", $0) }.joined()]
        default: return ["unknown op \(op)"]
        }
    }

    private static func level(_ name: String) -> PdfALevel {
        switch name.lowercased() {
        case "a1b": return .a1b
        case "a2b": return .a2b
        case "a2u": return .a2u
        case "a3b": return .a3b
        case "a3u": return .a3u
        case "a1a": return .a1a
        case "a2a": return .a2a
        case "a3a": return .a3a
        default: return .a4
        }
    }

    private static func plain(_ content: String = "BT /F1 12 Tf 20 100 Td (Hello world) Tj ET", catalog: String = "", page: String = "", resources: String = "",
                              extra: ((TestPdf) -> Void)? = nil) -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> \(resources)>> \(page)>>")
        pdf.stream(4, "", content)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        extra?(pdf)
        return pdf.finish("/Root 1 0 R")
    }

    private static func make(_ name: String, _ level: PdfALevel) -> [UInt8] {
        switch name {
        case "compliant":
            return StandardsKit.compliant(level)
        case "no-intent":
            return StandardsKit.compliant(level, intents: "")
        case "broken":
            return StandardsKit.compliant(level,
                catalog: "/AA << /WC << /S /URI /URI (x) >> >> /NeedsRendering false /OpenAction << /S /JavaScript /JS (1) >> /Names << /JavaScript << /Names [(a) << /S /JavaScript /JS (1) >>] >> >>",
                page: "/Annots [9 0 R 10 0 R 11 0 R] /AA << /O << /S /URI /URI (x) >> >>",
                content: "/G0 gs 0 0 0 1 k 0 0 5 5 re f BX 1 2 frob EX",
                resources: "/ExtGState <</G0 <</ca 0.5 /CA 0.5 /BM /Glow /TR /Identity /HTP /Default>>>>",
                extra: { pdf in
                    pdf.obj(9, "<</Type /Annot /Subtype /Sound /Rect [10 10 50 50] /F 4>>")
                    pdf.obj(10, "<</Type /Annot /Subtype /Square /Rect [60 10 90 50] /F 0 /C [1 0 0]>>")
                    pdf.obj(11, "<</Type /Annot /Subtype /Link /Rect [10 60 50 90] /F 4 /Border [0 0 0] /A << /S /Launch /F (a.exe) /Next << /S /Named /N /Print >> >>>>")
                })
        case "streams":
            return StandardsKit.compliant(level, catalog: "/Extra 9 0 R /More 12 0 R", extra: { pdf in
                pdf.stream(9, "/Filter /LZWDecode /F (a.txt)", PdfFilterEncoders.lzw(Array("abc".utf8)))
                pdf.stream(12, "/Filter /Fl", "abc")
                pdf.obj(4, "<</Length 5>>\nstream \n0 0 1 rg 20 20 100 100 re f\nendstream")
            })
        case "metadata":
            let packet = StandardsKit.packet(level)
                .replacingOccurrences(of: "<pdfaid:part>2<", with: "<pdfaid:part>1<")
                .replacingOccurrences(of: "<pdfaid:conformance>B<", with: "<pdfaid:conformance>X<")
            return StandardsKit.compliant(level, xmp: packet,
                info: "<</Title (Other) /Author (Someone) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103001Z) /ModDate (D:20260304103000Z)>>")
        case "layers":
            return StandardsKit.compliant(level, catalog: "/OCProperties << /OCGs [9 0 R] /D << /Order [] /AS [<< /Event /View >>] >> >>", extra: { pdf in
                pdf.obj(9, "<</Type /OCG /Name (L)>>")
            })
        case "attachment":
            return StandardsKit.compliant(level, catalog: "/Names << /EmbeddedFiles << /Names [(a.dat) 9 0 R] >> >>", extra: { pdf in
                pdf.obj(9, "<</Type /Filespec /F (a.dat) /UF (a.dat) /EF << /F 10 0 R >> >>")
                pdf.stream(10, "/Type /EmbeddedFile", "hello")
            })
        case "form":
            return StandardsKit.compliant(level, catalog: "/AcroForm << /Fields [9 0 R] /NeedAppearances true /DA (/Helv 12 Tf 0 g) /XFA [(a) 10 0 R] >>", page: "/Annots [9 0 R]", extra: { pdf in
                pdf.obj(9, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (abc) /Rect [10 10 100 30] /F 4 /AA << /K << /S /URI /URI (x) >> >>>>")
                pdf.stream(10, "", "x")
            })
        case "limits":
            return StandardsKit.compliant(level, catalog: "/Key /\(String(repeating: "a", count: 130)) /Big 3000000000 /Real 40000.5 /Text (\(String(repeating: "t", count: 70000)))",
                                          page: "/Odd <ABC>",
                                          content: String(repeating: "q ", count: 29) + String(repeating: "Q ", count: 29) + "0 0 1 rg 20 20 40000.5 100 re f")
        case "inline":
            return StandardsKit.compliant(level, content: "q BI /W 1 /H 1 /BPC 8 /CS /G /I true /F /Crypt ID x EI Q BI /W 1 /H 1 /BPC 8 /CS /RGB ID abc EI Q")
        case "a-good":
            return StandardsKit.tagged(level)
        case "a-unmarked":
            return StandardsKit.tagged(level, marked: "")
        case "a-nolang":
            return StandardsKit.tagged(level, lang: "")
        case "a-loose":
            return StandardsKit.tagged(level, content: "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC 1 0 0 rg 130 20 50 50 re f")
        case "a-noalt":
            return StandardsKit.tagged(level, alt: "")
        case "a-rolemap":
            return StandardsKit.tagged(level, roleMap: "/RoleMap <</Chart /Graph>>", figureType: "Chart")
        case "a-rolemap-ok":
            return StandardsKit.tagged(level, roleMap: "/RoleMap <</Chart /Figure>>", figureType: "Chart")
        case "a-noparents":
            return StandardsKit.tagged(level, structParents: "")
        case "a-wrongparent":
            return StandardsKit.tagged(level, parentTree: "[0 [10 0 R]]")
        case "a-part2-type":
            return StandardsKit.tagged(level, figureType: "Annot")
        case "plain":
            return plain()
        case "plain-lang":
            return plain(catalog: "/Lang (en-US)")
        case "transparency":
            return plain("/GS gs 0 g 0 0 50 50 re f", resources: "/ExtGState <</GS <</ca 0.5>>>>")
        case "lzw":
            return plain(extra: { pdf in
                pdf.stream(4, "/Filter /LZWDecode", PdfFilterEncoders.lzw(Array("BT /F1 12 Tf 20 100 Td (Hello world) Tj ET".utf8)))
            })
        default:
            preconditionFailure("no case \(name)")
        }
    }

    private static func check(_ level: PdfALevel, _ name: String) throws -> [String] {
        let document = try PdfDocument.open(make(name, level))
        let report = PdfAValidator.validate(document, level)
        var lines = ["issues \(report.issues.count) truncated \(report.truncated ? "true" : "false")"]
        for issue in report.issues { lines.append("  \(issue.clause) | \(show(issue.where)) | \(show(issue.message))") }
        return lines
    }

    private static func convert(_ level: PdfALevel, _ name: String) throws -> [String] {
        let result = try PdfAConverter().convert(make(name, level), level, day)
        var lines = ["refusal \(show(result.refusal ?? "none"))"]
        for change in result.changes { lines.append("change \(show(change))") }
        lines.append("remaining \(result.remaining.count) clean \(result.isClean ? "true" : "false")")
        for issue in result.remaining { lines.append("  \(issue.clause) | \(show(issue.where)) | \(show(issue.message))") }
        guard let bytes = result.bytes else { return lines }
        lines.append("header " + show(Latin1.string(Array(bytes.prefix(8)))))
        let document = try PdfDocument.open(bytes)
        for line in dump(document).components(separatedBy: "\n") { lines.append("  " + line) }
        return lines
    }

    private static func packet(_ level: PdfALevel, _ declare: Bool) -> String {
        let meta = DocumentMetadata("A & B <c> \"d\" \u{1F600}", "Au\r\nthor\tx", "  Sub\u{1}ject  ", "k1, k2", nil, "Prod",
                                    DateTimeOffset(2026, 1, 2, 3, 4, 5, offsetMinutes: -300), day, OrderedStrings())
        return Golden.escape(PdfAPacket.xmp(level, meta, day, declare))
    }

    private static func strip(_ escaped: String) -> String {
        guard let result = PdfAPacket.strip(String(decoding: Golden.unescape(escaped), as: UTF8.self)) else { return "null" }
        return Golden.escape(Array(result.utf8))
    }

    private static func show(_ text: String) -> String {
        var result = ""
        for c in text.utf16 {
            switch c {
            case 0x5C: result += "\\\\"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            default:
                if c < 0x20 || c >= 0x7F {
                    result += "\\u" + String(format: "%04x", UInt32(c))
                } else {
                    result.unicodeScalars.append(Unicode.Scalar(UInt8(c)))
                }
            }
        }
        return result
    }

    private static func data(_ document: PdfDocument, _ stream: PdfStream) -> String {
        guard let data = try? document.data(stream) else { return "unreadable" }
        let binary = data.contains { $0 < 0x20 && $0 != 9 && $0 != 10 && $0 != 13 }
        return data.count > 300 && binary ? "\(data.count) bytes" : show(Latin1.string(data))
    }

    // The dictionary without /Length, the size of the deflate of each side, and without a Flate filter, which the saver keeps only when the
    // deflate is smaller than the data, and the two deflates differ.
    private static func entries(_ dictionary: PdfDictionary) -> String {
        let shown = dictionary.entries.filter { $0.key != "Length" && !($0.key == "Filter" && ($0.value as? PdfName)?.value == "FlateDecode") }
        return "<<" + shown.map { "\(PdfName($0.key)) \($0.value)" }.joined(separator: " ") + ">>"
    }

    private static func dump(_ document: PdfDocument) -> String {
        var lines: [String] = []
        for number in document.objectNumbers {
            let text: String
            switch document.get(number) {
            case let stream as PdfStream: text = "stream \(entries(stream.dictionary)) | \(data(document, stream))"
            case let value?: text = value.description
            case nil: text = "null"
            }
            lines.append("\(number): \(text)")
        }
        return lines.joined(separator: "\n")
    }
}
