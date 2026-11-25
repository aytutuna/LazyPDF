import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Accessibility/PdfUaGolden.cs. One line of input is "<op> <case>" (the format is at the top of
// pdfua-input.txt): the issues the PDF/UA check finds in a file made from the name, and what marking it does. The files are made here
// from the names; the texts are English whatever the machine's language is.
enum PdfUaGolden {
    static func run(_ input: String) throws -> String {
        try L10n.english {
            var output = ""
            for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
                let words = line.components(separatedBy: " ")
                output += "> \(line)\n"
                for result in try op(words[0], words[1]) { output += "< \(result)\n" }
            }
            return output
        }
    }

    private static func op(_ op: String, _ name: String) throws -> [String] {
        switch op {
        case "check":
            return lines(try PdfUaKit.check(make(name)))
        case "mark":
            let document = try PdfDocument.open(make(name))
            let result = try PdfUaValidator.mark(document, PdfUaKit.date)
            let saved = try PdfDocument.open(try document.saveRewrite())
            return ["marked \(result.marked)"] + lines(result.blocking) + ["after \(try PdfUaValidator.validate(saved).issues.count)"]
        default:
            return ["unknown op \(op)"]
        }
    }

    private static func lines(_ report: PdfUaReport) -> [String] {
        ["issues \(report.issues.count) truncated \(report.truncated)"]
            + report.issues.map { "  \($0.condition) | \($0.clause) | \($0.where) | \($0.message)" }
    }

    private static func make(_ name: String) -> [UInt8] {
        switch name {
        case "compliant":
            return PdfUaKit.build()
        case "unmarked":
            return PdfUaKit.build(viewer: "", xmp: PdfUaKit.packet(ua: false))
        case "no-metadata":
            return PdfUaKit.build(viewer: "", xmp: "")
        case "no-title":
            return PdfUaKit.build(viewer: "", xmp: PdfUaKit.packet(ua: false, title: false), info: "<</Creator (Test)>>")
        case "untagged":
            return PdfUaKit.build(markInfo: "", tree: false)
        case "structure":
            return PdfUaKit.build(edit: { o in
                o[9] = "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R /RoleMap <</P /Span /A /B /B /A>>>>"
                o[10] = "<</Type /StructElem /S /Document /P 9 0 R /K [11 0 R 13 0 R 14 0 R 15 0 R 16 0 R 17 0 R 18 0 R 19 0 R]>>"
                o[11] = "<</Type /StructElem /S /Figure /P 10 0 R /Pg 3 0 R /K 0>>"
                o[13] = "<</Type /StructElem /S /Table /P 10 0 R /K 20 0 R>>"
                o[20] = "<</Type /StructElem /S /TD /P 13 0 R>>"
                o[14] = "<</Type /StructElem /S /L /P 10 0 R /K 21 0 R>>"
                o[21] = "<</Type /StructElem /S /Lbl /P 14 0 R>>"
                o[15] = "<</Type /StructElem /S /H2 /P 10 0 R>>"
                o[16] = "<</Type /StructElem /S /H /P 10 0 R>>"
                o[17] = "<</Type /StructElem /S /A /P 10 0 R>>"
                o[18] = "<</Type /StructElem /S /Weird /P 10 0 R>>"
                o[19] = "<</Type /StructElem /S /Note /P 10 0 R /Lang (x y)>>"
            })
        case "catalog":
            return PdfUaKit.build(
                markInfo: "/MarkInfo <</Marked true /Suspects true>>", lang: "/Lang (xx_y)", viewer: "",
                xmp: PdfUaKit.packet(ua: false, title: false),
                catalog: "/OCProperties <</OCGs [] /D <</AS []>>>> /NeedsRendering true /AcroForm <</Fields [] /XFA []>> /Names <</EmbeddedFiles <</Names [(a) 13 0 R]>>>>",
                page: "/Annots [14 0 R]",
                content: PdfUaKit.figure + " 1 0 0 rg 0 0 5 5 re f /Artifact BMC /Figure <</MCID 0>> BDC 0 0 1 rg 0 0 5 5 re f EMC EMC",
                resources: "/XObject <</X1 15 0 R /X2 16 0 R>>",
                extra: { pdf in
                    pdf.obj(13, "<</Type /Filespec /F (a.txt)>>")
                    pdf.obj(14, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10]>>")
                    pdf.stream(15, "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Ref <</F (x.pdf) /Page 0>>", "")
                    pdf.stream(16, "/Type /XObject /Subtype /PS", "")
                })
        case "text":
            return PdfUaKit.build(
                content: "/P <</MCID 0>> BDC BT /F1 12 Tf 20 100 Td (A) Tj ET EMC", resources: "/Font <</F1 13 0 R>>",
                edit: { o in o[11] = "<</Type /StructElem /S /P /P 10 0 R /Pg 3 0 R /K 0>>" },
                extra: { pdf in pdf.obj(13, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Type /Encoding /Differences [65 /zzunknown]>>>>") })
        default:
            fatalError("unknown case \(name)")
        }
    }
}
