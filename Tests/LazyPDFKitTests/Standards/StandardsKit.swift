import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/StandardsKit.cs: the same helpers. SystemFonts and its RequireArial are in
// FixtureFonts.swift: the fonts are made here, so no test asks whether Arial is installed.

enum StandardsKit {
    static let date = DateTimeOffset(2026, 3, 4, 10, 30, 0)

    private static let binary = "%\u{E2}\u{E3}\u{CF}\u{D3}\n"
    private static let ids = "/ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>]"

    /// A small file that follows PDF/A-2b: a blue square in DeviceRGB, the sRGB output intent, XMP identification and
    /// /Info in step (the shape Lazy Scan writes). `catalog`, `page` and `content` add to it.
    static func compliant(_ level: PdfALevel = .a2b, catalog: String = "", page: String = "", content: String = "0 0 1 rg 20 20 100 100 re f",
                          resources: String = "", extra: ((TestPdf) -> Void)? = nil, xmp: String? = nil, info: String = "", header: String = "",
                          intents: String = "/OutputIntents [6 0 R]") -> [UInt8] {
        let pdf = TestPdf(!header.isEmpty ? header : (level == .a4 ? "%PDF-2.0\n" : "%PDF-1.7\n") + binary)
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /Metadata 5 0 R \(intents) \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<\(resources)>> \(page)>>")
        pdf.stream(4, "", content)
        pdf.stream(5, "/Type /Metadata /Subtype /XML", Array((xmp ?? packet(level)).utf8))
        pdf.obj(6, "<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) /Info (sRGB IEC61966-2.1) /DestOutputProfile 7 0 R>>")
        pdf.stream(7, "/N 3", PdfASrgb.srgbProfile)
        let dates = "/CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)"
        pdf.obj(8, !info.isEmpty ? info : level == .a4 ? "<<\(dates)>>" : "<</Title (Title) /Creator (Test) /Producer (Test) \(dates)>>")
        extra?(pdf)
        return pdf.finish("/Root 1 0 R /Info 8 0 R \(ids)")
    }

    /// `compliant` with a structure tree: a Document holding one Figure that draws the blue square, with a description, the
    /// language and /MarkInfo. The arguments replace the parts a test breaks.
    static func tagged(_ level: PdfALevel, marked: String = "/MarkInfo <</Marked true>>", lang: String = "/Lang (en-US)", roleMap: String = "",
                       figureType: String = "Figure", alt: String = "/Alt (A blue square)",
                       content: String = "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC") -> [UInt8] {
        compliant(level, catalog: "/StructTreeRoot 9 0 R \(marked) \(lang)", page: "/StructParents 0", content: content, extra: { pdf in
            pdf.obj(9, "<</Type /StructTreeRoot /K 10 0 R /ParentTree 12 0 R \(roleMap)>>")
            pdf.obj(10, "<</Type /StructElem /S /Document /P 9 0 R /K 11 0 R>>")
            pdf.obj(11, "<</Type /StructElem /S /\(figureType) /P 10 0 R /Pg 3 0 R /K 0 \(alt)>>")
            pdf.obj(12, "<</Nums [0 [11 0 R]]>>")
        })
    }

    /// The XMP packet that goes with the info dictionary of `compliant`.
    static func packet(_ level: PdfALevel) -> String {
        let meta = level == .a4
            ? DocumentMetadata(nil, nil, nil, nil, nil, nil, date, date, OrderedStrings())
            : DocumentMetadata("Title", nil, nil, nil, "Test", "Test", date, date, OrderedStrings())
        return String(decoding: PdfAPacket.xmp(level, meta, date), as: UTF8.self)
    }

    static func check(_ file: [UInt8], _ level: PdfALevel = .a2b) throws -> PdfAReport {
        let document = try PdfDocument.open(file)
        return PdfAValidator.validate(document, level)
    }

    static func clauses(_ file: [UInt8], _ level: PdfALevel = .a2b) throws -> [String] {
        var seen = Set<String>()
        return try check(file, level).issues.map { $0.clause }.filter { seen.insert($0).inserted }
    }

    /// Rewrites the file after `edit` changed its objects, so that only the edit is wrong in it.
    static func edited(_ file: [UInt8], _ edit: (PdfDocument) throws -> Void) throws -> [UInt8] {
        let document = try PdfDocument.open(file)
        try edit(document)
        return try document.saveRewrite()
    }

    static func latin(_ file: [UInt8]) -> String { Latin1.string(file) }

    static func bytes(_ text: String) -> [UInt8] { Latin1.bytes(text) }

    static func assertClean(_ file: [UInt8], _ level: PdfALevel = .a2b, file path: StaticString = #filePath, line: UInt = #line) throws {
        let report = try check(file, level)
        XCTAssertTrue(report.isValid, report.issues.map { "\($0.clause) \($0.where): \($0.message)" }.joined(separator: "\n"), file: path, line: line)
    }

    /// Assert.Contains on the clauses.
    static func assertContains(_ clauses: [String], _ clause: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(clauses.contains(clause), "\(clause) is not in \(clauses)", file: file, line: line)
    }

    /// Assert.DoesNotContain on the clauses.
    static func assertLacks(_ clauses: [String], _ clause: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(clauses.contains(clause), "\(clause) is in \(clauses)", file: file, line: line)
    }

    /// Assert.Contains(issues, predicate).
    static func assertHas(_ issues: [PdfAIssue], _ message: String = "no issue like that", file: StaticString = #filePath, line: UInt = #line,
                          _ match: (PdfAIssue) -> Bool) {
        XCTAssertTrue(issues.contains(where: match), "\(message): \(issues.map { "\($0.clause) \($0.where): \($0.message)" })", file: file, line: line)
    }

    /// Assert.DoesNotContain(issues, predicate).
    static func assertNone(_ issues: [PdfAIssue], file: StaticString = #filePath, line: UInt = #line, _ match: (PdfAIssue) -> Bool) {
        XCTAssertFalse(issues.contains(where: match), "an issue like that is there: \(issues.map { "\($0.clause) \($0.where): \($0.message)" })", file: file, line: line)
    }
}
