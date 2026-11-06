import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/ExportLayoutTests.cs: the same cases.

final class ExportLayoutTests: XCTestCase {
    private func report() throws -> ExportDocument { try ExportLayout.analyze(ExportKit.report()) }

    private func paragraphs(_ blocks: [ExportBlock]) -> [ExportParagraph] { blocks.compactMap { $0 as? ExportParagraph } }

    func test_threePagesComeOutWithTheirSizeAndTitle() throws {
        let report = try report()
        XCTAssertEqual(report.pages.count, 3)
        for p in report.pages {
            XCTAssertEqual(p.width, 612)
            XCTAssertEqual(p.height, 792)
        }
        XCTAssertNil(report.title)
        XCTAssertEqual(report.bodySize, 11)
    }

    func test_runningHeadAndPageNumberAreLeftOutOfTheFlowButKeptWithTheirPlace() throws {
        for page in try report().pages {
            let text = paragraphs(page.blocks).map { $0.text }.joined(separator: "\n")
            XCTAssertFalse(text.contains("Confidential"))
            XCTAssertFalse(paragraphs(page.blocks).contains { $0.text == String(page.index + 1) })
            XCTAssertTrue(page.lines.contains { $0.text == "Confidential" && $0.bounds.y < 40 })
        }
    }

    func test_aLargerLineIsAHeading() throws {
        let headings = paragraphs(try report().pages[0].blocks).filter { $0.heading > 0 }
        XCTAssertEqual(headings.count, 1)
        XCTAssertEqual(headings[0].text, "Annual Report")
        XCTAssertEqual(headings[0].heading, 1)
    }

    func test_linesOfOneParagraphJoinAndAGapStartsAnother() throws {
        let plain = paragraphs(try report().pages[0].blocks).filter { $0.heading == 0 && $0.item == nil }
        XCTAssertEqual(plain[0].text, "First line of the opening paragraph that runs on to a second line and stops there.")
        XCTAssertEqual(plain[1].text, "Second paragraph with important words.")
    }

    func test_boldAndItalicRunsAreKept() throws {
        let second = paragraphs(try report().pages[0].blocks).filter { $0.text.hasPrefix("Second paragraph") }
        XCTAssertEqual(second.count, 1)
        // A space belongs to the run before it.
        let runs = second[0].runs
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(ExportTrim.both(runs[0].text), "Second paragraph with")
        XCTAssertEqual([runs[0].bold, runs[0].italic], [false, false])
        XCTAssertEqual(ExportTrim.both(runs[1].text), "important")
        XCTAssertEqual([runs[1].bold, runs[1].italic], [true, false])
        XCTAssertEqual(ExportTrim.both(runs[2].text), "words.")
        XCTAssertEqual([runs[2].bold, runs[2].italic], [false, true])
    }

    func test_bulletsAndNumbersMakeTwoLists() throws {
        let items = paragraphs(try report().pages[0].blocks).filter { $0.item != nil }
        XCTAssertEqual(items.map { $0.text }, ["Apples", "Pears", "First step", "Second step"])
        XCTAssertEqual(items.map { $0.item?.ordered }, [false, false, true, true])
        XCTAssertEqual(items[0].item?.listId, items[1].item?.listId)
        XCTAssertNotEqual(items[1].item?.listId, items[2].item?.listId)
        XCTAssertEqual(items[2].item?.listId, items[3].item?.listId)
        XCTAssertEqual(items[2].item?.number, 1)
        for i in items { XCTAssertEqual(i.item?.level, 0) }
    }

    func test_aGridOfRulesIsATableWithItsText() throws {
        let page = try report().pages[1]
        let tables = page.blocks.compactMap { $0 as? ExportTable }
        XCTAssertEqual(tables.count, 1)
        let table = tables[0]
        XCTAssertTrue(table.ruled)
        XCTAssertEqual(table.rows.map { $0.joined(separator: "|") }.joined(separator: ";"), "Item|Price;Tea|1,250.50")
        XCTAssertEqual(table.widths?.map { $0.rounded(.toNearestOrEven) }, [150, 150])
        XCTAssertFalse(paragraphs(page.blocks).contains { $0.text.contains("Tea") })
    }

    func test_thePictureSitsWhereItWasPaintedAndKeepsItsJpegBytes() throws {
        let page = try report().pages[0]
        XCTAssertEqual(page.pictures.count, 1)
        let picture = page.pictures[0]
        XCTAssertTrue(picture.image.isJpeg)
        XCTAssertEqual(picture.image.data, ExportKit.jpeg)
        XCTAssertEqual([picture.bounds.x, picture.bounds.y, picture.bounds.width, picture.bounds.height], [72, 470, 96, 72])
        XCTAssertTrue(page.blocks.compactMap { $0 as? ExportPicture }.contains { $0 === picture })
        let at = page.blocks.firstIndex { $0 === picture }
        let table = page.blocks.firstIndex { $0 is ExportTable }
        XCTAssertNotNil(table)
        XCTAssertGreaterThan(at ?? -1, table ?? Int.max)
    }

    func test_thePictureIsDecodedOncePerImageObject() throws {
        let report = try report()
        assertSame(report.pages[0].pictures[0].image, report.pages[2].pictures[0].image)
    }

    func test_aBoldLineAtBodySizeIsAHeadingOneLevelDown() throws {
        let document = try ExportLayout.analyze(ExportKit.open(
            "BT /F1 11 Tf 72 700 Td (Some body text that goes on for a while here.) Tj ET\nBT /F2 11 Tf 72 660 Td (Background) Tj ET\nBT /F1 11 Tf 72 640 Td (More body text that goes on for a while here.) Tj ET"))
        XCTAssertEqual(paragraphs(document.pages[0].blocks).map { $0.heading }, [0, 1, 0])
    }

    func test_sizesPickTheHeadingLevels() throws {
        let document = try ExportLayout.analyze(ExportKit.open(
            "BT /F2 24 Tf 72 740 Td (Title) Tj ET\nBT /F2 16 Tf 72 700 Td (Chapter) Tj ET\nBT /F1 11 Tf 72 670 Td (Body text that fills a line of the page nicely.) Tj ET\nBT /F1 11 Tf 72 656 Td (More body text that fills a line of the page nicely.) Tj ET"))
        XCTAssertEqual(paragraphs(document.pages[0].blocks).map { $0.heading }, [1, 2, 0])
    }

    func test_alignedColumnsWithoutRulesAreATable() throws {
        let rows = [("Name", "Qty", "Price"), ("Tea", "3", "4.50"), ("Coffee", "12", "18.00"), ("Milk", "7", "2.25")]
        let content = rows.enumerated().map { i, r in
            "BT /F1 11 Tf 72 \(700 - 16 * i) Td (\(r.0)) Tj ET BT /F1 11 Tf 220 \(700 - 16 * i) Td (\(r.1)) Tj ET BT /F1 11 Tf 320 \(700 - 16 * i) Td (\(r.2)) Tj ET"
        }.joined(separator: "\n")
        let tables = try ExportLayout.analyze(ExportKit.open(content)).pages[0].blocks.compactMap { $0 as? ExportTable }
        XCTAssertEqual(tables.count, 1)
        XCTAssertFalse(tables[0].ruled)
        XCTAssertEqual(tables[0].rows.count, 4)
        XCTAssertEqual(tables[0].rows[2], ["Coffee", "12", "18.00"])
        XCTAssertNil(tables[0].widths)
    }

    func test_anInvisibleTextScanDropsThePagePicture() throws {
        let document = try ExportLayout.analyze(ExportKit.open("q 612 0 0 792 0 0 cm /Im1 Do Q\nBT 3 Tr /F1 12 Tf 72 700 Td (Scanned words here) Tj ET"))
        XCTAssertTrue(document.pages[0].pictures.isEmpty)
        let found = paragraphs(document.pages[0].blocks)
        XCTAssertEqual(found.map { $0.text }, ["Scanned words here"])
    }

    func test_aRotatedPageIsAnalysedAsShown() throws {
        let text = TestPdf.text(ExportKit.build("BT /F1 12 Tf 72 700 Td (Rotated page) Tj ET")).replacingOccurrences(of: "/Type /Page /Parent", with: "/Type /Page /Rotate 90 /Parent")
        let document = try ExportLayout.analyze(PdfDocument.open(TestPdf.latin(text)))
        let page = document.pages[0]
        XCTAssertEqual(page.width, 792)
        XCTAssertEqual(page.height, 612)
        XCTAssertEqual(paragraphs(page.blocks).map { $0.text }, ["Rotated page"])
    }

    func test_pagesCanBeChosenAndABadIndexIsRefused() throws {
        let document = try ExportLayout.analyze(ExportKit.report(), [2, 0])
        XCTAssertEqual(document.pages.map { $0.index }, [2, 0])
        XCTAssertThrowsError(try ExportLayout.analyze(ExportKit.report(), [3])) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_anEmptyPageGivesAnEmptyFlow() throws {
        let document = try ExportLayout.analyze(ExportKit.open(""))
        XCTAssertTrue(document.pages[0].blocks.isEmpty)
        XCTAssertEqual(document.bodySize, 11)
    }

    func test_cancellationIsHonoured() async throws {
        let document = try ExportKit.report()
        let task = Task { () -> ExportDocument in
            while !Task.isCancelled { await Task.yield() }
            return try ExportLayout.analyze(document)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aDamagedContentStreamStillGivesWhatReadsBeforeIt() throws {
        let document = try ExportLayout.analyze(ExportKit.open("BT /F1 12 Tf 72 700 Td (Good text) Tj ET\n(((( [[ BT /Zz"))
        XCTAssertTrue(paragraphs(document.pages[0].blocks).map { $0.text }.contains("Good text"))
    }
}
