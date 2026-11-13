import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/PdfUaKit.cs: the same helpers.

enum PdfUaKit {
    static let date = DateTimeOffset(2026, 3, 4, 10, 30, 0)

    private static let ids = "/ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>]"

    static let figure = "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC"

    /// The packet of /Info's title and creator tool, with pdfuaid:part when `ua` is set.
    static func packet(ua: Bool = true, title: Bool = true) -> String {
        let meta = DocumentMetadata(title ? "Title" : nil, nil, nil, nil, "Test", "Test", date, date, OrderedStrings())
        let xmp = String(decoding: PdfAPacket.xmp(.a2b, meta, date, false), as: UTF8.self)
        return ua
            ? xmp.replacingOccurrences(of: "xmlns:dc=", with: "xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\"\n    xmlns:dc=")
                .replacingOccurrences(of: "   <dc:format>", with: "   <pdfuaid:part>1</pdfuaid:part>\n   <dc:format>")
            : xmp
    }

    /// The structure objects 9 to 12: Document, one Figure drawing the blue square, one parent tree array.
    static func objects() -> [Int: String] {
        [
            9: "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R>>",
            10: "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R>>",
            11: "<</Type /StructElem /S /Figure /P 10 0 R /Pg 3 0 R /K 0 /Alt (A blue square)>>",
            12: "<</Nums [0 [11 0 R]]>>",
        ]
    }

    /// A one-page file that follows PDF/UA-1. The arguments replace the parts a test breaks; `edit` changes the structure
    /// objects and `extra` adds objects from 13 on. An empty `xmp` leaves the packet out.
    static func build(markInfo: String = "/MarkInfo <</Marked true>>", lang: String = "/Lang (en-US)", viewer: String = "/ViewerPreferences <</DisplayDocTitle true>>",
                      xmp: String? = nil, tree: Bool = true, catalog: String = "", page: String = "/Tabs /S", content: String = figure, resources: String = "",
                      edit: ((inout [Int: String]) -> Void)? = nil, extra: ((TestPdf) -> Void)? = nil,
                      info: String = "<</Title (Title) /Creator (Test) /Producer (Test)>>") -> [UInt8] {
        var objects = objects()
        edit?(&objects)
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(xmp == "" ? "" : "/Metadata 5 0 R") \(tree ? "/StructTreeRoot 9 0 R" : "") \(markInfo) \(lang) \(viewer) \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<\(resources)>> /StructParents 0 \(page)>>")
        pdf.stream(4, "", content)
        if xmp != "" { pdf.stream(5, "/Type /Metadata /Subtype /XML", Array((xmp ?? packet()).utf8)) }
        pdf.obj(8, info)
        if tree {
            for number in objects.keys.sorted() { pdf.obj(number, objects[number]!) }
        }
        extra?(pdf)
        return pdf.finish("/Root 1 0 R /Info 8 0 R \(ids)")
    }

    static func check(_ file: [UInt8]) throws -> PdfUaReport {
        let document = try PdfDocument.open(file)
        return try PdfUaValidator.validate(document)
    }

    static func conditions(_ file: [UInt8]) throws -> [String] {
        var seen = Set<String>()
        return try check(file).issues.map { $0.condition }.filter { seen.insert($0).inserted }
    }

    static func describe(_ report: PdfUaReport) -> String {
        report.issues.map { "\($0.condition) \($0.clause) \($0.where): \($0.message)" }.joined(separator: "\n")
    }
}
