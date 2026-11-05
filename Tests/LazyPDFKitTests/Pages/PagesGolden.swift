import Foundation
import XCTest
@testable import LazyPDFKit

// Twin of windows/LazyPDF.Core.Tests/Pages/PagesGolden.cs. One line of input is "<op> <words>" (the format is at the top of
// pages-input.txt): typed page ranges, and whole documents after a page operation. A document is shown as every object of the
// file with the trailer, streams decoded, so that the numbers the importer and the page tree give to new objects are pinned too.
enum PagesGolden {
    static func run(_ input: String) throws -> String {
        var output = ""
        for line in input.components(separatedBy: "\n") where !line.isEmpty && !line.hasPrefix("# ") {
            let space = line.firstIndex(of: " ")
            let op = space.map { String(line[..<$0]) } ?? line
            let rest = space.map { String(line[line.index(after: $0)...]) } ?? ""
            output += "> \(line)\n"
            for result in try self.op(op, String(decoding: Golden.unescape(rest), as: UTF8.self)) { output += "< \(result)\n" }
        }
        return output
    }

    private static func op(_ op: String, _ rest: String) throws -> [String] {
        switch op {
        case "range": return [range(rest)]
        case "case": return try runCase(rest)
        default: return ["unknown op \(op)"]
        }
    }

    // text|page count
    private static func range(_ rest: String) -> String {
        guard let bar = rest.lastIndex(of: "|") else { return "format error" }
        let result = PageRange.parse(String(rest[..<bar]), Int(rest[rest.index(after: bar)...]) ?? 0)
        if let error = result.error { return "error \(show(error.message))" }
        return "pages [\(result.pages.map { String($0) }.joined(separator: ","))]"
    }

    private static func show(_ text: String) -> String {
        var result = ""
        for unit in text.utf16 {
            switch unit {
            case 0x5C: result += "\\\\"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            default:
                if unit < 0x20 || unit >= 0x7F {
                    result += "\\u" + String(format: "%04x", Int(unit))
                } else if let scalar = Unicode.Scalar(unit) {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    private static func dump(_ document: PdfDocument) throws -> [String] {
        var lines = ["trailer \(document.trailer)"]
        for number in document.objectNumbers {
            let text: String
            switch document.get(number) {
            case let stream as PdfStream: text = "stream \(stream.dictionary) | \(show(Latin1.string(try document.data(stream))))"
            case let value?: text = value.description
            case nil: text = "null"
            }
            lines.append("\(number): \(text)")
        }
        return lines
    }

    private static func parts(_ parts: [PdfDocument]) throws -> [String] {
        var lines: [String] = []
        for (i, part) in parts.enumerated() { lines += try dump(part).map { "part \(i) \($0)" } }
        return lines
    }

    // Page 1 has a text field, a note with its popup, links of each kind and a calculation order; page 2 the other widget of a field.
    private static func annotated() throws -> PdfDocument {
        let annots = "/Annots [40 0 R 41 0 R 42 0 R 43 0 R 44 0 R 45 0 R 46 0 R 50 0 R]"
        let form = "/AcroForm <</Fields [50 0 R 52 0 R] /CO [50 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 60 0 R>>>> /NeedAppearances true>>"
        return try PdfDocument.open(PageImportTests.source(annots, "/Dests <</five [5 0 R /Fit]>> " + form, { pdf in
            pdf.obj(40, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [5 0 R /Fit]>>")
                .obj(41, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [6 0 R /Fit]>>>>")
                .obj(42, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest /five>>")
                .obj(43, "<</Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (note) /Popup 44 0 R /P 4 0 R /StructParent 3>>")
                .obj(44, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 43 0 R /Open true>>")
                .obj(45, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://example.com)>>>>")
                .obj(46, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 99 0 R>>")
                .obj(50, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /DA (/Helv 12 Tf 0 g) /Rect [0 0 50 20]>>")
                .obj(51, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 30 50 50]>>")
                .obj(52, "<</T (grp) /FT /Tx /V (G) /Kids [51 0 R 53 0 R]>>")
                .obj(53, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 60 50 80]>>")
                .obj(60, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        }, extra5: "/Annots [51 0 R 53 0 R]"))
    }

    // Four pages with an outline, named destinations, links, an open action, labels, threads, fields and actions that share followers.
    private static func linked() throws -> PdfDocument {
        let outline = 12
        let n = PageTestFiles.free(4) + 20
        return try PageTestFiles.open(4,
            "/Outlines \(outline) 0 R /OpenAction 70 0 R /PageLabels <</Nums [0 <</S /r>> 2 <</S /D /St 5>>]>> /Threads [\(n) 0 R] "
                + "/Dests <</a [5 0 R /Fit] /b [6 0 R /Fit]>> /Names <</Dests <</Names [(c) [5 0 R /Fit] (d) [6 0 R /Fit] (e) <</D [4 0 R /Fit]>>]>>>> "
                + "/AcroForm <</Fields [\(n + 20) 0 R \(n + 21) 0 R] /CO [\(n + 20) 0 R \(n + 21) 0 R]>>",
            pageExtra: { i in
                switch i {
                case 0: return "/Annots [\(n + 10) 0 R \(n + 11) 0 R \(n + 20) 0 R]"
                case 1: return "/Annots [\(n + 22) 0 R]"
                case 2: return "/Annots [\(n + 23) 0 R]"
                default: return ""
                }
            },
            add: { pdf in
                pdf.obj(outline, "<</Type /Outlines /First \(outline + 1) 0 R /Last \(outline + 4) 0 R /Count 4>>")
                pdf.obj(outline + 1, "<</Title (One) /Parent \(outline) 0 R /Next \(outline + 2) 0 R /Dest [4 0 R /Fit]>>")
                pdf.obj(outline + 2, "<</Title (Two) /Parent \(outline) 0 R /Prev \(outline + 1) 0 R /Next \(outline + 3) 0 R /Dest [5 0 R /XYZ 0 0 0] /First \(outline + 5) 0 R /Last \(outline + 5) 0 R /Count 1>>")
                pdf.obj(outline + 3, "<</Title (Three) /Parent \(outline) 0 R /Prev \(outline + 2) 0 R /Next \(outline + 4) 0 R /A <</S /GoTo /D [7 0 R /Fit]>>>>")
                pdf.obj(outline + 4, "<</Title (Four) /Parent \(outline) 0 R /Prev \(outline + 3) 0 R /Dest (c)>>")
                pdf.obj(outline + 5, "<</Title (Child) /Parent \(outline + 2) 0 R /Dest [6 0 R /Fit]>>")
                pdf.obj(70, "<</S /GoTo /D [5 0 R /Fit] /Next [71 0 R 72 0 R [71 0 R]]>>")
                pdf.obj(71, "<</S /URI /URI (http://a)>>")
                pdf.obj(72, "<</S /URI /URI (http://b)>>")
                pdf.obj(n, "<</Type /Thread /F \(n + 1) 0 R>>")
                pdf.obj(n + 1, "<</Type /Bead /T \(n) 0 R /N \(n + 2) 0 R /V \(n + 3) 0 R /P 4 0 R /R [0 0 10 10]>>")
                pdf.obj(n + 2, "<</Type /Bead /N \(n + 3) 0 R /V \(n + 1) 0 R /P 5 0 R /R [0 0 10 10]>>")
                pdf.obj(n + 3, "<</Type /Bead /N \(n + 1) 0 R /V \(n + 2) 0 R /P 6 0 R /R [0 0 10 10]>>")
                pdf.obj(n + 10, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [6 0 R /Fit]>>")
                pdf.obj(n + 11, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A 73 0 R>>")
                pdf.obj(73, "<</S /GoTo /D [5 0 R /Fit] /Next [71 0 R 74 0 R]>>")
                pdf.obj(74, "<</S /URI /URI (http://c) /Next 75 0 R>>")
                pdf.obj(75, "<</S /GoTo /D [6 0 R /Fit]>>")
                pdf.obj(n + 20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /V (x) /Rect [0 0 10 10]>>")
                pdf.obj(n + 21, "<</FT /Tx /T (b) /V (y) /Kids [\(n + 22) 0 R \(n + 23) 0 R]>>")
                pdf.obj(n + 22, "<</Type /Annot /Subtype /Widget /Parent \(n + 21) 0 R /Rect [0 0 10 10]>>")
                pdf.obj(n + 23, "<</Type /Annot /Subtype /Widget /Parent \(n + 21) 0 R /Rect [0 0 10 10]>>")
            })
    }

    // A page with a pattern, a shared pattern dictionary, annotations of each geometry and boxes.
    private static func drawn() throws -> PdfDocument {
        let pdf = TestPdf()
            .obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 200 300]>>")
            .obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Pattern <</P1 6 0 R /P2 7 0 R>>>> /TrimBox [10 10 190 290] /BleedBox [0 0 300 300] /Annots [8 0 R]>>")
            .obj(4, "<</Type /Page /Parent 2 0 R /Contents [9 0 R 10 0 R] /Rotate 90 /UserUnit 2 /Resources <</Pattern <</P2 7 0 R>>>>>>")
            .stream(5, "", "/Pattern cs /P1 scn 0 0 100 100 re f /P2 scn 0 0 10 10 re f")
            .stream(6, "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Matrix [1 0 0 1 5 5]", "0 0 5 5 re f")
            .obj(7, "<</PatternType 2 /Shading <</ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1>>>>>>")
            .obj(8, "<</Type /Annot /Subtype /Ink /Rect [20 30 60 90] /InkList [[20 30 40 60 60 90] [1 2]] /RD [1 2 3 4] /QuadPoints [20 30 60 30 20 90 60 90] /L [0 0 10 10] /Vertices [1 2 3] /CL [1 2 3 4 5 6]>>")
            .stream(9, "", "0 0 m 10 10 l S")
            .stream(10, "", "5 5 m 20 20 l S")
        return try PdfDocument.open(pdf.finish())
    }

    private static func runCase(_ name: String) throws -> [String] {
        let document: PdfDocument
        switch name {
        case "rotate":
            document = try PageTestFiles.open(3, rootExtra: "/Rotate 90")
            PageOperations.rotate(document, [0, 2], 90)
            PageOperations.rotate(document, [1], -90)
            PageOperations.rotate(document, [2], 360)
        case "boxes":
            document = try PageTestFiles.open(2, pageExtra: { $0 == 0 ? "/TrimBox [0 0 100 100] /ArtBox [5 5 6 6]" : "" })
            try PageOperations.setBox(document, [1], .crop, PdfRect(10, 20, 110, 220))
            try PageOperations.setBox(document, [0, 1], .art, PdfRect(20, 30, 100, 400))
            try PageOperations.setBox(document, [0], .trim, nil)
            try PageOperations.setBox(document, [1], .media, PdfRect(0, 0, 400, 500))
            PageOperations.removeTransitions(document, [0, 1])
        case "resize-scale":
            document = try drawn()
            try PageOperations.resize(document, [0, 1], 400, 300, .scaleContent)
        case "resize-box":
            document = try drawn()
            try PageOperations.resize(document, [1, 0], 100, 150, .changeBox)
        case "delete":
            document = try linked()
            try PageOperations.delete(document, [1, 3])
        case "delete-first":
            document = try linked()
            try PageOperations.delete(document, [0])
        case "delete-tagged":
            document = try PageTestFiles.open(3, "/StructTreeRoot 40 0 R /MarkInfo <</Marked true>>", pageExtra: { "/StructParents \($0)" },
                                              add: { $0.obj(40, "<</Type /StructTreeRoot>>") })
            try PageOperations.delete(document, [1])
        case "reorder":
            document = try PageTestFiles.open(70)
            try PageOperations.reorder(document, Array((0..<70).reversed()))
        case "move":
            document = try PageTestFiles.open(5, "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D>>]>>")
            try PageOperations.move(document, [1, 2], 5)
            try PageOperations.move(document, [4, 3], 0)
        case "duplicate":
            document = try annotated()
            try PageOperations.duplicate(document, [0, 2])
        case "insert-blank":
            document = try PageTestFiles.open(4, "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D>>]>>")
            try PageOperations.insertBlank(document, 2, 595.5, 842, 2)
            try PageOperations.insertBlank(document, 0, 100, 100)
        case "import":
            document = try PageTestFiles.open(2)
            try PageOperations.importPages(document, try PdfDocument.open(PageImportTests.source()), [2, 0, 0], 1)
        case "import-annotated":
            document = try PageTestFiles.open(1)
            try PageOperations.importPages(document, try annotated(), [0, 1], 1)
            try PageOperations.importPages(document, try annotated(), [0], 0)
        case "import-self":
            document = try annotated()
            try PageOperations.importPages(document, document, [1, 0], 2)
        case "extract":
            return try dump(try PageAssembly.extract(try annotated(), [1, 0]))
        case "extract-linked":
            return try dump(try PageAssembly.extract(try linked(), [3, 0]))
        case "merge":
            return try dump(try PageAssembly.merge([MergeSource(try PageTestFiles.open(2)), MergeSource(try annotated(), [0, 1]),
                                                    MergeSource(try PdfDocument.open(PageImportTests.source()), [2])]))
        case "split-every":
            return try parts(try PageAssembly.splitEvery(try PageTestFiles.open(5), 2))
        case "split-at":
            return try parts(try PageAssembly.splitAt(try linked(), [3, 1]))
        case "split-size":
            return try parts(try PageAssembly.splitBySize(try PageTestFiles.open(6), 1400))
        default:
            return ["unknown case \(name)"]
        }
        return try dump(document)
    }
}
