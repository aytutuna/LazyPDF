import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportReviewFixTests.cs: the same cases. The tests of linear time keep their
// shape with a bound that a debug build meets (a quadratic walk takes minutes); the C# regular expressions are scans for
// the same text.

final class ExportReviewFixTests: XCTestCase {
    private let s = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    private func line(_ text: String, _ x: Double, _ y: Double, _ width: Double = 40, _ before: TextBreak = .line) -> ExLine {
        ExLine(box: DisplayRect(x, y, width, 10), runs: [ExportRun(text, false, false, 10)], size: 10, allBold: false, before: before, block: 0)
    }

    private func onePage(_ width: Double, _ height: Double, _ blocks: [ExportBlock]) -> ExportDocument {
        ExportDocument(nil, [ExportPage(0, width, height, blocks, [], [])], 11)
    }

    private func picture(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ bytes: Int = 8) -> ExportPicture {
        ExportPicture(DisplayRect(x, y, w, h), ExportImage([UInt8](repeating: 0, count: bytes), true, 8, 6))
    }

    private func count(_ text: String, _ part: String) -> Int { text.components(separatedBy: part).count - 1 }

    private func seconds(_ since: Date) -> Double { Date().timeIntervalSince(since) }

    func test_aNonAsciiDigitIsNotAListMarker() {
        let rows = ExportFlow.rows([line("\u{663}. hello there", 72, 700)])
        let found = ExportFlow.paragraphs(rows)
        XCTAssertEqual(found.count, 1)
        XCTAssertNil(found[0].item)
        XCTAssertFalse(ExportFlow.isMarker("\u{663}."))
    }

    func test_theRtfBulletIsAnEscapeAndTheFileStaysSevenBit() throws {
        let item = ExportParagraph(DisplayRect(72, 72, 100, 12), [ExportRun("Apples", false, false, 11)], 0, ExportListItem(1, false, 0, 0))
        let rtf = try RtfWriter.make(onePage(612, 792, [item]))
        XCTAssertTrue(rtf.contains(#"\fi-360 "# + "\\u8226?" + #"\tab "#))
        XCTAssertTrue(rtf.unicodeScalars.allSatisfy { $0.value < 128 })
    }

    func test_aMarkerFindsItsTextAmongManyLines() {
        var lines: [ExLine?] = [line("text", 80, 100), line("•", 70, 100, 5), line("other", 80, 300)]
        ExportFlow.joinMarkers(&lines)
        XCTAssertNil(lines[1])
        XCTAssertEqual(lines[0]?.text, "• text")
        XCTAssertEqual(lines[2]?.text, "other")
    }

    func test_aPageOfBareMarkersIsJoinedInLinearTime() {
        var lines: [ExLine?] = (0..<30000).map { line("•", 10, 12.0 * Double($0), 5) }
        let start = Date()
        ExportFlow.joinMarkers(&lines)
        XCTAssertLessThan(seconds(start), 30, "took \(seconds(start)) s")
    }

    func test_aPictureOnAStampSizedPageHasAPositiveExtent() throws {
        let document = onePage(30, 40, [picture(2, 2, 26, 36)])
        let xml = try ExportKit.unzip(DocxWriter.make(document), "word/document.xml")
        let extents = xml.components(separatedBy: "<wp:extent cx=\"").dropFirst().map { part -> (Int?, Int?) in
            let pieces = part.components(separatedBy: "\"")
            return (Int(pieces[0]), pieces.count > 2 ? Int(pieces[2]) : nil)
        }
        XCTAssertFalse(extents.isEmpty)
        for (cx, cy) in extents { XCTAssertTrue((cx ?? 0) > 0 && (cy ?? 0) > 0) }
        let (width, height) = DocxWriter.paperTwips(document)
        let (top, right, bottom, left) = DocxWriter.marginsTwips(document, width, height)
        XCTAssertTrue(width - left - right > 0 && height - top - bottom > 0)
        let rtf = try RtfWriter.make(document)
        XCTAssertFalse(rtf.contains("picwgoal-"))
        XCTAssertFalse(rtf.contains("pichgoal-"))
    }

    func test_picturesPastTheEmbeddingBudgetAreRefusedNotDropped() throws {
        let big = ExportImage([UInt8](repeating: 0, count: 12 << 20), true, 8, 6)
        func many(_ count: Int) -> ExportDocument {
            onePage(612, 792, (0..<count).map { ExportPicture(DisplayRect(10, Double(10 + 20 * $0), 10, 10), big) })
        }
        let over = many(50)
        for write in [{ try HtmlWriter.reflowed(over) }, { try MarkdownWriter.make(over, embedImages: true) }, { try RtfWriter.make(over) }] {
            XCTAssertThrowsError(try write()) { XCTAssertTrue($0 is PdfReadException) }
        }
        XCTAssertEqual(count(try MarkdownWriter.make(over), "data:image"), 0)

        let under = many(3)
        XCTAssertEqual(count(try HtmlWriter.reflowed(under), "<img"), 3)
        XCTAssertEqual(count(try MarkdownWriter.make(under, embedImages: true), "data:image"), 3)
        XCTAssertEqual(count(try RtfWriter.make(under), "jpegblip"), 3)
    }

    func test_theTextBudgetCountsRunsAndNotOnlyCharacters() throws {
        var content = "BT /F1 4 Tf "
        for i in 0..<20000 { content += "1 0 0 1 \(10 + i % 50 * 11) \(780 - Double(i / 50) * 1.5) Tm (x) Tj " }
        content += "ET"
        let document = try ExportKit.open(content)
        XCTAssertThrowsError(try ExportLayout.analyze(document, [Int](repeating: 0, count: 180))) { XCTAssertTrue($0 is PdfReadException) }
        XCTAssertFalse(try ExportLayout.analyze(document, [Int](repeating: 0, count: 3)).pages.isEmpty)
    }

    func test_markersAtTheEdgeOfTheirReachAreJoinedInLinearTime() {
        var lines: [ExLine?] = []
        for _ in 0..<100000 { lines.append(line("text", 80, 100)) }
        for _ in 0..<100000 { lines.append(line("•", 70, 105, 5)) }
        let start = Date()
        ExportFlow.joinMarkers(&lines)
        XCTAssertLessThan(seconds(start), 60, "took \(seconds(start)) s")
    }

    func test_aRtfTableStopsAtWordsColumnLimit() throws {
        let row = (0..<70).map { "c\($0)" }
        let table = ExportTable(DisplayRect(10, 10, 500, 20), [row], nil, true)
        let rtf = try RtfWriter.make(onePage(612, 792, [table]))
        XCTAssertEqual(count(rtf, #"\cellx"#), 63)
        XCTAssertEqual(count(rtf, #"\cell"#) - count(rtf, #"\cellx"#), 63)
        XCTAssertTrue(rtf.contains("c62 c63 c64"))
        XCTAssertTrue(rtf.contains("c69"))
    }

    func test_aSheetStopsAtTheLastRowExcelAllows() throws {
        let rows = [[String]](repeating: ["a"], count: 1048577)
        let table = ExportTable(DisplayRect(10, 10, 500, 20), rows, nil, true)
        let xml = try ExportKit.unzip(XlsxWriter.make(onePage(612, 792, [table])), "xl/worksheets/sheet1.xml")
        XCTAssertTrue(xml.contains("<row r=\"1048576\">"))
        XCTAssertFalse(xml.contains("r=\"1048577\""))
    }

    func test_thousandsOfLinesPastTheLastColumnJoinInLinearTime() throws {
        let lines = (0..<200000).map { ExportTextLine(DisplayRect(10 + 20.0 * Double($0), 10, 1, 10), [ExportRun("w", false, false, 10)]) }
        let page = ExportDocument(nil, [ExportPage(0, 612, 792, [], lines, [])], 11)
        let start = Date()
        let sheet = try ExportKit.part(XlsxWriter.make(page), "xl/worksheets/sheet1.xml")
        XCTAssertLessThan(seconds(start), 120, "took \(seconds(start)) s")
        XCTAssertEqual(ExportKit.descendants(sheet, s, "t").last?.value.utf16.count, 32767)
    }

    func test_aZipWithTheZip64CountOfEntriesIsRefused() throws {
        var entries = (0..<Int(UInt16.max)).map { ExportZipEntry("e\($0)", []) }
        XCTAssertThrowsError(try ExportZip.make(entries)) { XCTAssertTrue($0 is PdfReadException) }
        entries.removeFirst()
        XCTAssertFalse(try ExportZip.make(entries).isEmpty)
    }

    func test_aPackageOverTheSizeLimitIsRefused() {
        let data = [UInt8](repeating: 0, count: 600 << 20)
        XCTAssertThrowsError(try ExportZip.make([ExportZipEntry("a", data), ExportZipEntry("b", data)])) { XCTAssertTrue($0 is PdfReadException) }
    }

    func test_anOversizedPresentationIsAReadProblem() {
        let pages = (0..<33000).map { ExportPage($0, 100, 100, [], [], []) }
        XCTAssertThrowsError(try PptxWriter.make(ExportDocument(nil, pages, 11))) { XCTAssertTrue($0 is PdfReadException) }
    }

    func test_aWideTableStopsAtWordsColumnLimit() throws {
        let row = (0..<70).map { "c\($0)" }
        let table = ExportTable(DisplayRect(10, 10, 500, 20), [row, row], nil, true)
        let xml = try ExportKit.unzip(DocxWriter.make(onePage(612, 792, [table])), "word/document.xml")
        XCTAssertEqual(count(xml, "<w:gridCol "), 63)
        XCTAssertEqual(count(xml, "<w:tc>"), 2 * 63)
        XCTAssertTrue(xml.contains("c62 c63 c64"))
        XCTAssertTrue(xml.contains("c69"))
    }

    func test_aSheetKeepsToExcelsCellColumnAndRowLimits() throws {
        let table = ExportTable(DisplayRect(10, 10, 500, 20), [[String(repeating: "x", count: 40000), "b"]], nil, true)
        let sheet = try ExportKit.part(XlsxWriter.make(onePage(612, 792, [table])), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(ExportKit.descendants(sheet, s, "t").first?.value.utf16.count, 32767)

        let lines = (0..<16500).map { ExportTextLine(DisplayRect(Double(10 + $0), 10, 1, 10), [ExportRun("w\($0)", false, false, 10)]) }
        let page = ExportDocument(nil, [ExportPage(0, 612, 792, [], lines, [])], 11)
        let wide = try ExportKit.part(XlsxWriter.make(page), "xl/worksheets/sheet1.xml")
        let dimensions = ExportKit.descendants(wide, s, "dimension")
        XCTAssertEqual(dimensions.count, 1)
        XCTAssertEqual(dimensions[0].attribute(XmlName("", "ref"))?.value, "A1:XFD1")
        for c in ExportKit.descendants(wide, s, "c") { XCTAssertLessThanOrEqual((c.attribute(XmlName("", "r"))?.value ?? "").count, 6) }
    }
}
