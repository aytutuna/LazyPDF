import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/ReadingOrderTests.cs: the same cases.

final class ReadingOrderTests: XCTestCase {
    func test_followsTheTagsOfAHandMadeFile() throws {
        let document = try TaggedFile.open()

        XCTAssertEqual(ReadingOrder.export(document), "# Head\nBody text\n[Figure: A picture]")
    }

    func test_changingTheTagOrderChangesTheReadOut() throws {
        let document = try TaggedFile.open()
        let tree = try XCTUnwrap(StructureTree.read(document))
        try tree.move(try XCTUnwrap(tree.elements.first { $0.type == "Figure" }), tree.roots[0], 0)

        XCTAssertEqual(ReadingOrder.export(document, tree), "[Figure: A picture]\n# Head\nBody text")
    }

    func test_anUntaggedFileReadsAsNothing() throws {
        let document = try PdfDocument.open(AccessKit.report(1))

        XCTAssertEqual(ReadingOrder.export(document), "")
    }

    func test_reportReadsHeadingParagraphsListTableAndFigureInOrder() throws {
        let document = try PdfDocument.open(AccessKit.report(3))
        _ = try AutoTagger.tag(document)
        let lines = ReadingOrder.export(document).components(separatedBy: "\n")

        let page = [
            "# Introduction",
            "This is the first paragraph of page 1. It has enough words to fill two lines of the body text.",
            "A second paragraph follows after a clear gap.",
            "\u{2022} First item",
            "\u{2022} Second item",
            "\u{2022} Third item",
            "Name\tCount\tPrice",
            "Apples\t12\t3.50",
            "Pears\t7\t4.25",
            "[Figure]",
        ]
        XCTAssertEqual(lines.count, page.count * 3)
        XCTAssertEqual(Array(lines.prefix(page.count)), page)
        XCTAssertEqual(lines[page.count], "# Introduction")
        XCTAssertTrue(lines[page.count + 1].contains("page 2."))
    }

    func test_figureAltTextIsRead() throws {
        let document = try PdfDocument.open(AccessKit.report(1))
        _ = try AutoTagger.tag(document)
        let tree = try XCTUnwrap(StructureTree.read(document))
        try XCTUnwrap(tree.elements.first { $0.type == "Figure" }).alt = "Fruit sales"
        try tree.write(document)

        XCTAssertTrue(ReadingOrder.export(document).hasSuffix("[Figure: Fruit sales]"))
    }

    func test_reorderingTheTreeReordersTheOutputOfAnAutoTaggedFile() throws {
        let document = try PdfDocument.open(AccessKit.report(1))
        _ = try AutoTagger.tag(document)
        let tree = try XCTUnwrap(StructureTree.read(document))
        try tree.move(try XCTUnwrap(tree.elements.first { $0.type == "Table" }), tree.roots[0], 0)
        try tree.write(document)

        let again = try AccessKit.reopen(document, rewrite: true)
        XCTAssertTrue(ReadingOrder.export(again).hasPrefix("Name\tCount\tPrice\nApples"))
    }

    func test_textOfAnActualTextSpanAndInlineChildrenStaysInOneLine() throws {
        let document = try PdfDocument.open(TaggedFile.build({ o in
            o[9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R]>>"
            o[11] = "<</Type /StructElem /S /P /P 9 0 R /Pg 3 0 R /K [1 14 0 R]>>"
            o[14] = "<</Type /StructElem /S /Span /P 11 0 R /Pg 3 0 R /K 3>>"
            o[13] = "<</Nums [0 [10 0 R 11 0 R 12 0 R 14 0 R]]>>"
        }, content: TaggedFile.content + "/Span <</MCID 3>> BDC " + AccessKit.text(150, 670, "and more") + " EMC\n"))

        XCTAssertEqual(ReadingOrder.export(document), "# Head\nBody text and more\n[Figure: A picture]")
    }
}
