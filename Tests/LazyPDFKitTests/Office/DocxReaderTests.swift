import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Office/DocxReaderTests.cs and reads the same golden files.

final class DocxReaderTests: XCTestCase {
    func test_docxGoldenFile() throws {
        var output = ""
        for (name, package) in try DocxSpec.read(try Golden.input("office-docx", "docx-input.txt")) {
            output += "> \(name)\n" + DocxSpec.dump(try DocxReader.read(package))
        }
        try Golden.check("office-docx", "docx-output.txt", output)
    }

    func test_docxTablesGoldenFile() throws {
        var output = ""
        for (name, package) in try DocxSpec.read(try Golden.input("office-docx", "tables-input.txt")) {
            output += "> \(name)\n" + DocxSpec.dump(try DocxReader.read(package))
        }
        try Golden.check("office-docx", "tables-output.txt", output)
    }

    private func docx(_ body: String, styles: String? = nil) throws -> [UInt8] {
        var parts = [(key: "document", text: body)]
        if let styles { parts.append(("styles", styles)) }
        return try DocxSpec.package(parts)
    }

    private func zip(_ parts: (String, String)...) throws -> [UInt8] {
        try ExportZip.make(parts.map { ExportZipEntry($0.0, Array($0.1.utf8)) })
    }

    private func problem(_ work: () throws -> Void) -> PdfReadProblem? {
        do {
            try work()
            return nil
        } catch let e as PdfReadException {
            return e.problem
        } catch {
            return nil
        }
    }

    private static let types = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"
    private static let rels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"r1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"/word/document.xml\"/></Relationships>"
    private static let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""

    func test_listLabelsStayShortForCraftedNumbering() throws {
        let numbering = "<w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"99999999\"/><w:numFmt w:val=\"lowerLetter\"/><w:lvlText w:val=\"" +
            String(repeating: "%1", count: 500) + "\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        let body = "<w:p><w:pPr><w:numPr><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>x</w:t></w:r></w:p>"
        let package = try DocxSpec.package([("numbering", numbering), ("document", body)])
        let document = try DocxReader.read(package)
        let paragraph = try XCTUnwrap(document.sections[0].blocks[0] as? LayoutParagraph)
        let text = paragraph.runs[0].text
        XCTAssertLessThanOrEqual(text.utf16.count, 64 + 2 + 1)
        XCTAssertTrue(text.hasSuffix("\tx"))
    }

    func test_numberFormats() {
        let cases: [(Int, String, String)] = [
            (1, "lowerLetter", "a"), (27, "lowerLetter", "aa"), (4, "upperRoman", "IV"), (1994, "lowerRoman", "mcmxciv"),
            (4000, "upperRoman", "4000"), (7, "decimalZero", "07"), (12, "decimalZero", "12"), (5, "unknownFormat", "5"),
        ]
        for (value, format, expected) in cases { XCTAssertEqual(DocxNumbering.format(value, format), expected, format) }
    }

    func test_readsAMinimalPackageWithAnAbsoluteTarget() throws {
        let package = try zip(("[Content_Types].xml", Self.types), ("_rels/.rels", Self.rels),
                              ("word/document.xml", "<w:document \(Self.w)><w:body><w:p><w:r><w:t>hi</w:t></w:r></w:p></w:body></w:document>"))
        let document = try DocxReader.read(package)
        XCTAssertEqual(document.sections[0].blocks.count, 1)
        let paragraph = try XCTUnwrap(document.sections[0].blocks[0] as? LayoutParagraph)
        XCTAssertEqual(paragraph.runs.count, 1)
        XCTAssertEqual(paragraph.runs[0].text, "hi")
        XCTAssertEqual(paragraph.runs[0].size, 10)
        XCTAssertEqual(paragraph.runs[0].family, "Times New Roman")
    }

    func test_refusesWhatIsNotAWordDocument() throws {
        XCTAssertEqual(problem { _ = try DocxReader.read(try self.zip(("a.txt", "x"))) }, .damaged)
        XCTAssertEqual(problem { _ = try DocxReader.read(try self.zip(("[Content_Types].xml", Self.types))) }, .damaged)
        XCTAssertEqual(problem { _ = try DocxReader.read([1, 2, 3, 4, 5]) }, .damaged)

        let sheet = Self.types.replacingOccurrences(of: "wordprocessingml.document", with: "spreadsheetml.sheet")
        let excel = try zip(("[Content_Types].xml", sheet), ("_rels/.rels", Self.rels), ("word/document.xml", "<w:document \(Self.w)><w:body/></w:document>"))
        XCTAssertEqual(problem { _ = try DocxReader.read(excel) }, .unsupported)

        let strict = try zip(("[Content_Types].xml", Self.types), ("_rels/.rels", Self.rels),
                             ("word/document.xml", "<w:document xmlns:w=\"http://purl.oclc.org/ooxml/wordprocessingml/main\"><w:body/></w:document>"))
        XCTAssertEqual(problem { _ = try DocxReader.read(strict) }, .unsupported)

        let old: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]
        XCTAssertEqual(problem { _ = try DocxReader.read(old) }, .unsupported)
    }

    func test_refusesNestingPastTheXmlLimit() throws {
        let body = String(repeating: "<w:sdt><w:sdtContent>", count: 100) + "<w:p/>" + String(repeating: "</w:sdtContent></w:sdt>", count: 100)
        let package = try docx(body)
        XCTAssertEqual(problem { _ = try DocxReader.read(package) }, .unsupported)
    }

    func test_controlsNestedWithinTheLimitAreRead() throws {
        let body = String(repeating: "<w:sdt><w:sdtContent>", count: 40) + "<w:p><w:r><w:t>deep</w:t></w:r></w:p>" + String(repeating: "</w:sdtContent></w:sdt>", count: 40)
        let document = try DocxReader.read(try docx(body))
        XCTAssertEqual(document.sections[0].blocks.count, 1)
        XCTAssertEqual((document.sections[0].blocks[0] as? LayoutParagraph)?.runs[0].text, "deep")
    }

    func test_manyParagraphsAreReadAndCancellationStopsTheRead() async throws {
        let package = try docx(String(repeating: "<w:p><w:r><w:t>x</w:t></w:r></w:p>", count: 5000))
        XCTAssertEqual(try DocxReader.read(package).sections[0].blocks.count, 5000)
        let task = Task { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try DocxReader.read(package).sections.count
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("the read went on")
        } catch is CancellationError {
        }
    }

    func test_numbersFollowTheCSharpParser() {
        XCTAssertEqual(DocxReader.number(" 12 "), 12)
        XCTAssertEqual(DocxReader.number("-1.5e1"), -15)
        XCTAssertEqual(DocxReader.number(".5"), 0.5)
        XCTAssertEqual(DocxReader.number("5."), 5)
        XCTAssertEqual(DocxReader.number("+7"), 7)
        for bad in ["", "x", "-", ".", "1e", "1e+", "1 2", "0x10", "nan", "inf", "1e999", "1,5"] { XCTAssertNil(DocxReader.number(bad), bad) }
        XCTAssertNil(DocxReader.number(nil))
        XCTAssertEqual(DocxReader.hex("2F5496"), 0x2F5496)
        for bad in ["2F549", "2F54960", "+F5496", "GG0000", " 2F549"] { XCTAssertNil(DocxReader.hex(bad), bad) }
    }

    func test_convertsToAPdfWithTheTextAndThePageBreaks() throws {
        let body =
            "<w:p><w:r><w:t>First page</w:t></w:r></w:p>" +
            "<w:p><w:r><w:br w:type=\"page\"/><w:t>Second page</w:t></w:r></w:p>" +
            "<w:p><w:pPr><w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/></w:sectPr></w:pPr></w:p>" +
            "<w:p><w:r><w:t>Third page</w:t></w:r></w:p>" +
            "<w:tbl><w:tr><w:tc><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"
        let made = try OfficeConverter.fromWord(try docx(body), OfficeLayoutSpec.fonts())
        XCTAssertEqual(made.pages, 3)
        XCTAssertFalse(made.skipped.contains { $0.kind == "table" })
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertEqual(pdf.pages.count, 3)
        func text(_ i: Int) -> String { TextPage.create(pdf, pdf.pages[i]).text.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(text(0), "First page")
        XCTAssertEqual(text(1), "Second page")
        XCTAssertTrue(text(2).contains("Third page"))
        XCTAssertTrue(text(2).contains("cell"))
    }

    func test_pageNumberFieldsInTheFooterShowThePageAndTheCount() throws {
        let footer = "<w:p><w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText>PAGE</w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType=\"end\"/></w:r><w:r><w:t>/</w:t></w:r><w:fldSimple w:instr=\"NUMPAGES\"><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p>"
        let parts = [
            (key: "document", text: "<w:p><w:r><w:t>a</w:t></w:r></w:p><w:p><w:r><w:br w:type=\"page\"/><w:t>b</w:t></w:r></w:p><w:sectPr><w:footerReference w:type=\"default\" r:id=\"rIdF\"/></w:sectPr>"),
            (key: "footer", text: footer),
        ]
        let made = try OfficeConverter.fromWord(try DocxSpec.package(parts), OfficeLayoutSpec.fonts())
        let pdf = try PdfDocument.open(made.bytes)
        XCTAssertEqual(pdf.pages.count, 2)
        func text(_ i: Int) -> String { TextPage.create(pdf, pdf.pages[i]).text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "") }
        XCTAssertTrue(text(0).contains("1/2"))
        XCTAssertTrue(text(1).contains("2/2"))
    }
}
