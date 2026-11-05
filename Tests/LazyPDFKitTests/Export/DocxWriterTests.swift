import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/DocxWriterTests.cs: the same cases. The lone surrogate of the text in
// XmlSpecialsAreEscapedAndImpossibleCharactersLeftOut cannot be a Swift character, so U+FFFE stands for it. The Turkish
// sentence is the letters of the synthetic font, which Arial is not available for.

final class DocxWriterTests: XCTestCase {
    private let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private let rel = "http://schemas.openxmlformats.org/package/2006/relationships"

    private func package() throws -> [UInt8] { try DocxWriter.make(ExportLayout.analyze(ExportKit.report())) }

    private func one(_ blocks: [ExportBlock]) -> ExportDocument {
        ExportDocument("t", [ExportPage(0, 612, 792, blocks, [], [])], 11)
    }

    private func attribute(_ element: XmlElement, _ namespace: String, _ local: String) -> String? {
        element.attribute(XmlName(namespace, local))?.value
    }

    func test_everyPartIsWellFormedAndEveryCrcIsRight() throws {
        let files = try ExportZipReader.read(package())
        for entry in files {
            XCTAssertEqual(entry.crc, ExportZip.crc32(entry.data), entry.name)
            if entry.name.hasSuffix(".xml") || entry.name.hasSuffix(".rels") {
                XCTAssertNotNil(XmlDocument.parse(entry.data), entry.name)
            }
        }
        XCTAssertTrue(files.map { $0.name }.contains("word/document.xml"))
    }

    func test_relationshipsPointAtPartsThatExist() throws {
        let package = try package()
        let entries = try ExportKit.entries(package)
        let rels = try ExportKit.part(package, "word/_rels/document.xml.rels").elements(XmlName(rel, "Relationship"))
        for item in rels { XCTAssertTrue(entries.contains("word/" + (item.attribute(XmlName("", "Target"))?.value ?? "")), "\(item)") }
        var used: [String] = []
        for element in ExportKit.descendants(try ExportKit.part(package, "word/document.xml")) {
            if let id = element.attribute(XmlName(r, "embed"))?.value { used.append(id) }
        }
        XCTAssertFalse(used.isEmpty)
        for id in used { XCTAssertTrue(rels.contains { $0.attribute(XmlName("", "Id"))?.value == id }, id) }
        let types = try ExportKit.unzip(package, "[Content_Types].xml")
        XCTAssertTrue(types.contains("image/jpeg"))
        XCTAssertTrue(types.contains("wordprocessingml.document.main+xml"))
    }

    func test_headingsParagraphsRunsAndPageBreaksAreWritten() throws {
        let package = try package()
        let root = try ExportKit.part(package, "word/document.xml")
        let body = try XCTUnwrap(root.element(XmlName(w, "body")))
        let paragraphs = body.elements(XmlName(w, "p"))
        let heading = try XCTUnwrap(paragraphs.first { $0.value == "Annual Report" })
        let styles = ExportKit.descendants(heading, w, "pStyle")
        XCTAssertEqual(styles.count, 1)
        XCTAssertEqual(attribute(styles[0], w, "val"), "Heading1")
        let second = try XCTUnwrap(paragraphs.first { $0.value == "Second paragraph with important words." })
        let runs = second.elements(XmlName(w, "r"))
        XCTAssertEqual(runs.filter { !ExportKit.descendants($0, w, "b").isEmpty }.count, 1)
        XCTAssertEqual(runs.filter { !ExportKit.descendants($0, w, "i").isEmpty }.count, 1)
        XCTAssertEqual(ExportKit.descendants(body, w, "pageBreakBefore").count, 2)
    }

    func test_listsUseNumberingAndTheTableHasItsGrid() throws {
        let package = try package()
        let body = try XCTUnwrap(try ExportKit.part(package, "word/document.xml").element(XmlName(w, "body")))
        let numIds = Set(ExportKit.descendants(body, w, "numId").compactMap { attribute($0, w, "val") })
        XCTAssertEqual(numIds.count, 6)
        let numbering = try ExportKit.part(package, "word/numbering.xml")
        let nums = numbering.elements(XmlName(w, "num"))
        XCTAssertEqual(nums.count, 6)
        XCTAssertEqual(nums.filter { !ExportKit.descendants($0, w, "startOverride").isEmpty }.count, 3)

        let table = try XCTUnwrap(body.elements(XmlName(w, "tbl")).first)
        let rows = table.elements(XmlName(w, "tr"))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(try XCTUnwrap(table.element(XmlName(w, "tblGrid"))).elements(XmlName(w, "gridCol")).count, 2)
        XCTAssertEqual(rows[0].elements(XmlName(w, "tc")).map { $0.value }, ["Item", "Price"])
        XCTAssertEqual(rows[rows.count - 1].elements(XmlName(w, "tc")).last?.value, "1,250.50")
    }

    func test_thePictureIsInlineAndItsMediaIsTheJpegAsStored() throws {
        let package = try package()
        let document = try ExportKit.part(package, "word/document.xml")
        let extent = try XCTUnwrap(ExportKit.descendants(document).first { $0.name.local == "extent" })
        XCTAssertEqual(Int(attribute(extent, "", "cx") ?? ""), 96 * 12700)
        XCTAssertEqual(Int(attribute(extent, "", "cy") ?? ""), 72 * 12700)
        let media = try ExportKit.entries(package).filter { $0.hasPrefix("word/media/") }
        XCTAssertEqual(media.count, 1)
        let stored = try ExportZipReader.read(package).first { $0.name == media[0] }
        XCTAssertEqual(stored?.data, ExportKit.jpeg)
    }

    func test_paperAndMarginsFollowThePage() throws {
        let document = try ExportKit.part(package(), "word/document.xml")
        let sections = ExportKit.descendants(document, w, "sectPr")
        XCTAssertEqual(sections.count, 1)
        let size = try XCTUnwrap(sections[0].element(XmlName(w, "pgSz")))
        XCTAssertEqual(attribute(size, w, "w"), "12240")
        XCTAssertEqual(attribute(size, w, "h"), "15840")
        let margin = try XCTUnwrap(sections[0].element(XmlName(w, "pgMar")))
        XCTAssertEqual(attribute(margin, w, "left"), "1440")
    }

    func test_xmlSpecialsAreEscapedAndImpossibleCharactersLeftOut() throws {
        let document = one([ExportParagraph(DisplayRect(72, 72, 100, 12), [ExportRun("a < b & c > \"d\" \u{1}x\u{FFFE}y\tz", false, false, 11)])])
        let root = try ExportKit.part(DocxWriter.make(document), "word/document.xml")
        XCTAssertEqual(ExportKit.descendants(root, w, "t").map { $0.value }, ["a < b & c > \"d\" xy", "z"])
        XCTAssertEqual(ExportKit.descendants(root, w, "tab").count, 1)
    }

    func test_turkishTextSurvivesFromPdfThroughDocxXml() throws {
        let turkish = "AB ğ İ BA À"
        let made = try PdfFromText.create(turkish, fonts: ExportArialSource())
        let reopened = try PdfDocument.open(made.bytes)
        let package = try DocxWriter.make(ExportLayout.analyze(reopened))
        let text = ExportKit.descendants(try ExportKit.part(package, "word/document.xml"), w, "t").map { $0.value }.joined()
        XCTAssertEqual(ExportTrim.both(text), turkish)
    }

    func test_anEmptyDocumentIsStillAValidPackage() throws {
        let package = try DocxWriter.make(ExportDocument(nil, [], 11))
        let body = try XCTUnwrap(try ExportKit.part(package, "word/document.xml").element(XmlName(w, "body")))
        XCTAssertNotNil(body.element(XmlName(w, "p")))
        XCTAssertNotNil(body.element(XmlName(w, "sectPr")))
    }

    func test_theTitleGoesToTheCoreProperties() throws {
        let package = try DocxWriter.make(ExportDocument("Rapor & özet", [], 11))
        XCTAssertTrue(try ExportKit.unzip(package, "docProps/core.xml").contains("Rapor &amp; özet"))
        XCTAssertTrue(try ExportKit.unzip(package, "_rels/.rels").contains("core-properties"))
    }

    func test_nestedListsKeepTheirLevels() throws {
        let document = one([
            ExportParagraph(DisplayRect(72, 72, 100, 12), [ExportRun("top", false, false, 11)], 0, ExportListItem(1, false, 0, 0)),
            ExportParagraph(DisplayRect(90, 90, 100, 12), [ExportRun("inner", false, false, 11)], 0, ExportListItem(1, false, 1, 0)),
        ])
        let levels = ExportKit.descendants(try ExportKit.part(DocxWriter.make(document), "word/document.xml"), w, "ilvl").compactMap { attribute($0, w, "val") }
        XCTAssertEqual(levels, ["0", "1"])
    }
}
