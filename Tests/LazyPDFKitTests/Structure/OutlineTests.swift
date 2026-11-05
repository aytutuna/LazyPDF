import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/OutlineTests.cs: the same cases. The bookmarks PdfPig reads in
// PdfPigReadsTheBookmarks and LinksOfOutlineMatchPdfPigAfterEdit are read with Outline.read from the rewritten file
// instead.

final class OutlineTests: XCTestCase {
    // Chapter 1 (open) has two children, chapter 2 (closed) has one, chapter 3 has none. The counts are
    // wrong on purpose: a write must work them out again.
    private func sample() throws -> PdfDocument {
        try StructureFixtures.file("/Outlines 20 0 R /Names <</Dests <</Names [(target) [4 0 R /Fit]]>>>>", { pdf in
            pdf.obj(20, "<</Type /Outlines /First 21 0 R /Last 23 0 R /Count 99>>")
            pdf.obj(21, "<</Title (Chapter 1) /Parent 20 0 R /Next 22 0 R /First 24 0 R /Last 25 0 R /Count 7 /Dest [3 0 R /XYZ 0 300 null] /C [1 0 0] /F 3 /Unknown (kept)>>")
            pdf.obj(22, "<</Title (Chapter 2) /Parent 20 0 R /Prev 21 0 R /Next 23 0 R /First 26 0 R /Last 26 0 R /Count -1 /Dest (target) /SE 21 0 R>>")
            pdf.obj(23, "<</Title (Chapter 3) /Parent 20 0 R /Prev 22 0 R /Dest [5 0 R /Fit]>>")
            pdf.obj(24, "<</Title (Section 1.1) /Parent 21 0 R /Next 25 0 R /A <</S /URI /URI (http://example.com)>>>>")
            pdf.obj(25, "<</Title <FEFF04160410> /Parent 21 0 R /Prev 24 0 R /A <</S /GoTo /D [5 0 R /FitH 10]>>>>")
            pdf.obj(26, "<</Title (Appendix \\(a\\)) /Parent 22 0 R>>")
        })
    }

    private func saved(_ document: PdfDocument) throws -> PdfDocument {
        try StructureFixtures.reopen(document)
    }

    private func item(_ title: String, destination: PdfDestination? = nil, action: PdfAction? = nil) -> OutlineItem {
        let item = OutlineItem()
        item.title = title
        item.destination = destination
        item.action = action
        return item
    }

    private func titles(_ items: [OutlineItem]) -> [String] {
        items.map { $0.title }
    }

    func test_readsTheTree() throws {
        let outline = Outline.read(try sample())
        XCTAssertEqual(titles(outline.items), ["Chapter 1", "Chapter 2", "Chapter 3"])
        let one = outline.items[0]
        XCTAssertTrue(one.isOpen)
        XCTAssertFalse(outline.items[1].isOpen)
        XCTAssertEqual([one.color?.r, one.color?.g, one.color?.b], [1, 0, 0])
        XCTAssertTrue(one.bold)
        XCTAssertTrue(one.italic)
        XCTAssertEqual(one.destination, PdfDestination(0, .xyz, left: 0, top: 300))
        XCTAssertEqual(titles(one.children), ["Section 1.1", "\u{416}\u{410}"])
        XCTAssertEqual((one.children[0].action as? UriAction)?.uri, "http://example.com")
        XCTAssertNil(one.children[0].destination)
        XCTAssertEqual(one.children[1].destination?.pageIndex, 2)
        XCTAssertEqual(outline.items[1].children.map { $0.title }, ["Appendix (a)"])
        XCTAssertEqual(outline.items[1].destination?.pageIndex, 1)
        XCTAssertEqual(outline.items[1].destination?.name, "target")
        assertSame(one, one.children[0].parent)
    }

    func test_noOutlinesIsEmpty() throws {
        XCTAssertTrue(Outline.read(try StructureFixtures.open()).items.isEmpty)
    }

    func test_writeFixesCountsAndKeepsUnknownKeys() throws {
        let document = try sample()
        let outline = Outline.read(document)
        try outline.write(document)
        let reopened = try saved(document)

        let root = try XCTUnwrap(reopened.dict(reopened.catalog, "Outlines"))
        XCTAssertEqual(reopened.integer(root, "Count"), 5)
        let first = try XCTUnwrap(reopened.dict(root, "First"))
        XCTAssertEqual(reopened.integer(first, "Count"), 2)
        XCTAssertEqual(PdfText.read(reopened, first, "Unknown"), "kept")
        let second = try XCTUnwrap(reopened.dict(first, "Next"))
        XCTAssertEqual(reopened.integer(second, "Count"), -1)
        XCTAssertNotNil(second["SE"])
        XCTAssertNil(reopened.dict(second, "Next")?["Count"])

        let again = Outline.read(reopened)
        XCTAssertEqual(titles(outline.items), titles(again.items))
        XCTAssertEqual(outline.items[1].destination, again.items[1].destination)
    }

    func test_untouchedActionsAndDestinationsAreNotRewritten() throws {
        let document = try sample()
        let before = try XCTUnwrap(document.dict(document.dict(document.catalog, "Outlines"), "First"))
        let item25 = try XCTUnwrap(document.dict(document.dict(before, "First"), "Next"))
        let action = try XCTUnwrap(item25["A"]).description
        let outline = Outline.read(document)
        outline.items[0].children[1].title = "Renamed"
        try outline.write(document)
        XCTAssertEqual(item25["A"]?.description, action)
        XCTAssertNil(item25["Dest"])
    }

    func test_pdfPigReadsTheBookmarks() throws {
        let document = try sample()
        try Outline.read(document).write(document)
        let read = Outline.read(try PdfDocument.open(document.saveRewrite()))
        XCTAssertEqual(read.items.count, 3)
        XCTAssertEqual(read.items[0].title, "Chapter 1")
        XCTAssertEqual(read.items[0].children.count, 2)
    }

    func test_buildFromNothing() throws {
        let document = try StructureFixtures.open()
        let outline = Outline.read(document)
        let a = try outline.add(item("Intro", destination: StructureFixtures.toPage(0)))
        a.isOpen = true
        let b = try outline.add(item("T\u{FC}rk\u{E7}e \u{11F}", destination: StructureFixtures.toPage(1)))
        b.bold = true
        b.color = (0, 0, 1)
        try outline.add(item("Detail", destination: StructureFixtures.toPage(2)), a)
        try outline.add(item("Link", action: UriAction("http://x")), a)
        try outline.write(document)

        let reopened = try saved(document)
        let read = Outline.read(reopened)
        XCTAssertEqual(titles(read.items), ["Intro", "T\u{FC}rk\u{E7}e \u{11F}"])
        XCTAssertEqual(titles(read.items[0].children), ["Detail", "Link"])
        XCTAssertEqual(read.items[1].destination?.pageIndex, 1)
        XCTAssertTrue(read.items[1].bold)
        XCTAssertEqual([read.items[1].color?.r, read.items[1].color?.g, read.items[1].color?.b], [0, 0, 1])
        XCTAssertEqual(reopened.integer(reopened.dict(reopened.catalog, "Outlines"), "Count"), 4)
        XCTAssertEqual((read.items[0].children[1].action as? UriAction)?.uri, "http://x")
        XCTAssertNotNil(b.reference)
    }

    func test_closedItemKeepsNegativeCount() throws {
        let document = try StructureFixtures.open()
        let outline = Outline.read(document)
        let parent = try outline.add(item("p", destination: StructureFixtures.toPage(0)))
        try outline.add(item("c1", destination: StructureFixtures.toPage(0)), parent)
        try outline.add(item("c2", destination: StructureFixtures.toPage(0)), parent)
        try outline.write(document)
        XCTAssertEqual(document.integer(parent.source, "Count"), -2)
        XCTAssertEqual(document.integer(document.dict(document.catalog, "Outlines"), "Count"), 1)

        parent.isOpen = true
        try outline.write(document)
        XCTAssertEqual(document.integer(parent.source, "Count"), 2)
        XCTAssertEqual(document.integer(document.dict(document.catalog, "Outlines"), "Count"), 3)
    }

    func test_removeFreesTheSubtree() throws {
        let document = try sample()
        let outline = Outline.read(document)
        let gone = outline.items[0]
        outline.remove(gone)
        try outline.write(document)
        XCTAssertNil(document.get(21))
        XCTAssertNil(document.get(24))
        XCTAssertNil(document.get(25))
        XCTAssertNotNil(document.get(22))

        let reopened = try saved(document)
        let read = Outline.read(reopened)
        XCTAssertEqual(titles(read.items), ["Chapter 2", "Chapter 3"])
        XCTAssertEqual(reopened.integer(reopened.dict(reopened.catalog, "Outlines"), "Count"), 2)
    }

    func test_removingEverythingTakesOutlinesAway() throws {
        let document = try sample()
        let outline = Outline.read(document)
        for item in outline.items { outline.remove(item) }
        try outline.write(document)
        XCTAssertNil(document.catalog["Outlines"])
        XCTAssertNil(document.get(20))
        XCTAssertTrue(Outline.read(try saved(document)).items.isEmpty)
    }

    func test_renameAndMove() throws {
        let document = try sample()
        let outline = Outline.read(document)
        let chapter3 = outline.items[2]
        chapter3.title = "Last chapter"
        try outline.move(chapter3, outline.items[0], 0)
        try outline.move(outline.items[1], nil, 0)
        try outline.write(document)

        let read = Outline.read(try saved(document))
        XCTAssertEqual(titles(read.items), ["Chapter 2", "Chapter 1"])
        XCTAssertEqual(titles(read.items[1].children), ["Last chapter", "Section 1.1", "\u{416}\u{410}"])
        XCTAssertEqual(read.items[1].children.count, 3)
    }

    func test_moveWithinTheSameParentTakesTheIndexAfterTheRemoval() throws {
        let outline = Outline.read(try sample())
        let first = outline.items[0]
        try outline.move(first, nil, 3)
        XCTAssertEqual(titles(outline.items), ["Chapter 2", "Chapter 3", "Chapter 1"])
        try outline.move(first, nil, 0)
        XCTAssertEqual(outline.items[0].title, "Chapter 1")
    }

    func test_changedDestinationReplacesTheAction() throws {
        let document = try sample()
        let outline = Outline.read(document)
        let link = outline.items[0].children[0]
        link.destination = StructureFixtures.toPage(2)
        try outline.write(document)
        let source = try XCTUnwrap(link.source)
        XCTAssertNil(source["A"])
        XCTAssertEqual(PdfDestinations.parse(document, source["Dest"])?.pageIndex, 2)

        let goTo = outline.items[0].children[1]
        goTo.destination = nil
        try outline.write(document)
        let goToSource = try XCTUnwrap(goTo.source)
        XCTAssertNil(goToSource["A"])
        XCTAssertNil(goToSource["Dest"])
        XCTAssertNil(goTo.action)
    }

    func test_changedActionReplacesTheDestination() throws {
        let document = try sample()
        let outline = Outline.read(document)
        let item = outline.items[0]
        item.action = NamedAction("NextPage")
        try outline.write(document)
        let source = try XCTUnwrap(item.source)
        XCTAssertNil(source["Dest"])
        XCTAssertEqual((PdfActions.read(document, source["A"]) as? NamedAction)?.name, "NextPage")
    }

    func test_itemWithAPageThatIsGoneKeepsItsDestination() throws {
        let document = try StructureFixtures.file("/Outlines 20 0 R", { pdf in
            pdf.obj(20, "<</Type /Outlines /First 21 0 R /Last 21 0 R /Count 1>>")
            pdf.obj(21, "<</Title (Old) /Parent 20 0 R /Dest [77 0 R /Fit]>>")
        })
        let outline = Outline.read(document)
        XCTAssertEqual(outline.items[0].destination?.pageIndex, -1)
        outline.items[0].title = "Still old"
        try outline.write(document)
        XCTAssertEqual(outline.items[0].source?["Dest"]?.description, "[77 0 R /Fit]")
    }

    func test_loopsInTheChainsAreCut() throws {
        let document = try StructureFixtures.file("/Outlines 20 0 R", { pdf in
            pdf.obj(20, "<</Type /Outlines /First 21 0 R>>")
            pdf.obj(21, "<</Title (a) /Parent 20 0 R /Next 22 0 R /First 20 0 R>>")
            pdf.obj(22, "<</Title (b) /Parent 20 0 R /Next 21 0 R /First 22 0 R>>")
        })
        let outline = Outline.read(document)
        XCTAssertEqual(titles(outline.items), ["a", "b"])
        for item in outline.items { XCTAssertTrue(item.children.isEmpty) }
        try outline.write(document)
        XCTAssertEqual(Outline.read(try StructureFixtures.reopen(document)).items.count, 2)
    }

    func test_brokenChainsAreCutAtTheBreak() throws {
        let document = try StructureFixtures.file("/Outlines 20 0 R", { pdf in
            pdf.obj(20, "<</Type /Outlines /First 21 0 R>>")
            pdf.obj(21, "<</Title (a) /Next 99 0 R /First 23 0 R>>")
            pdf.obj(23, "<</Title (kid) /Next 24 0 R>>")
            pdf.obj(24, "(not a dictionary)")
        })
        let outline = Outline.read(document)
        XCTAssertEqual(outline.items.count, 1)
        XCTAssertEqual(titles(outline.items[0].children), ["kid"])
    }

    func test_titlelessItemsAreEmptyTitles() throws {
        let document = try StructureFixtures.file("/Outlines 20 0 R", { pdf in
            pdf.obj(20, "<</First 21 0 R>>")
            pdf.obj(21, "<</Dest [3 0 R /Fit]>>")
        })
        let items = Outline.read(document).items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "")
    }

    func test_deepNestingIsCutAtSixtyFourLevels() throws {
        let document = try StructureFixtures.file("/Outlines 20 0 R", { pdf in
            pdf.obj(20, "<</First 21 0 R>>")
            for i in 0..<200 { pdf.obj(21 + i, "<</Title (L\(i)) /First \(22 + i) 0 R>>") }
        })
        var depth = 0
        var level = Outline.read(document).items
        while level.count == 1 {
            depth += 1
            level = level[0].children
        }
        XCTAssertTrue(level.isEmpty)
        XCTAssertEqual(depth, 64)
    }

    func test_largeOutlineWritesAndReads() throws {
        let document = try StructureFixtures.open()
        let outline = Outline.read(document)
        for i in 0..<3000 { try outline.add(item("Item \(i)", destination: StructureFixtures.toPage(i % 3))) }
        try outline.write(document)
        let read = Outline.read(try saved(document))
        XCTAssertEqual(read.items.count, 3000)
        XCTAssertEqual(read.items.last?.title, "Item 2999")
        XCTAssertEqual(read.items[2999].destination?.pageIndex, 2)
    }

    func test_linksOfOutlineMatchPdfPigAfterEdit() throws {
        let document = try sample()
        let outline = Outline.read(document)
        try outline.move(outline.items[2], outline.items[0])
        try outline.write(document)
        let read = Outline.read(try PdfDocument.open(document.saveRewrite()))
        XCTAssertEqual(read.items.count, 2)
        XCTAssertEqual(read.items[0].children.count, 3)
    }

    func test_itemCannotMoveIntoItself() throws {
        let outline = Outline.read(try sample())
        let one = outline.items[0]
        XCTAssertThrowsError(try outline.move(one, one)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try outline.move(one, one.children[0])) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try outline.add(one.children[0], one)) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try outline.move(OutlineItem(), nil)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_anActionReadFromAFileThatCannotBeWrittenStopsTheWrite() throws {
        let document = try sample()
        let outline = Outline.read(document)
        outline.items[0].action = OtherAction("Hide")
        XCTAssertThrowsError(try outline.write(document)) { XCTAssertTrue($0 is ArgumentException) }
    }
}
