import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/standards/TagTreeAndReadingTests.cs: the labels of the tag tree, the reading order
// lines and what a voice is given, and taking back a half-done edit. The rows of the tree that open on demand (TagNode) are new
// on Apple and have their cases at the end.

final class TagTreeAndReadingTests: XCTestCase {
    private func page(_ number: Int) -> String {
        (0..<12).map { "Paragraph \($0) of page \(number) has its own words and numbers \(number * 100 + $0)." }.joined(separator: "\n\n")
    }

    private func tagged() throws -> PdfDocument {
        let document = try PdfDocument.open(PdfFromText.create(page(1) + "\u{0C}" + page(2), fonts: FakeFonts()).bytes)
        _ = try AutoTagger.tag(document)
        return try PdfDocument.open(document.saveIncremental())
    }

    func test_aTagReadsAsItsTypeAndPage() throws {
        let tree = try XCTUnwrap(StructureTree.read(tagged()))
        let paragraph = try XCTUnwrap(tree.elements.first { $0.type == "P" })

        XCTAssertEqual(TagLabels.of(paragraph, tree), "P, page 1")
    }

    func test_aDescriptionIsShownBesideTheTagAndCutShort() throws {
        let tree = StructureTree.create(try PdfDocument.open(Pdfs.text()))
        let figure = StructElement("Figure")
        figure.alt = String(repeating: "x", count: 100)
        try tree.add(nil, figure)

        XCTAssertEqual(TagLabels.of(figure, tree), "Figure: " + String(repeating: "x", count: 60) + "...")
    }

    func test_aCustomTagShowsWhatItMapsTo() throws {
        let tree = StructureTree.create(try PdfDocument.open(Pdfs.text()))
        tree.roleMap["Chapter"] = "H1"
        let element = StructElement("Chapter")
        try tree.add(nil, element)

        XCTAssertEqual(TagLabels.of(element, tree), "Chapter (H1)")
    }

    func test_theReadingOrderIsOneLinePerBlockInTagOrder() throws {
        let lines = ReadingLines.of(ReadingOrder.export(try tagged()))

        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.contains("Paragraph 5 of page 1") })
        let first = try XCTUnwrap(lines.firstIndex { $0.contains("of page 1") })
        let second = try XCTUnwrap(lines.firstIndex { $0.contains("of page 2") })
        XCTAssertLessThan(first, second)
    }

    func test_aFileWithoutTagsHasNoReadingOrder() throws {
        XCTAssertTrue(ReadingLines.of(ReadingOrder.export(try PdfDocument.open(Pdfs.text()))).isEmpty)
    }

    func test_aVoiceIsGivenTheWordsWithoutTheMarksOfStructure() {
        let cases = [("## Chapter two", "Chapter two"), ("[Figure: A grey square]", "Figure: A grey square"),
                     ("Name\tCount\tPrice", "Name,Count,Price"), ("Plain words.", "Plain words."), ("###", "")]
        for (line, spoken) in cases { XCTAssertEqual(ReadingLines.spoken(line), spoken, line) }
    }

    @MainActor
    func test_discardingTakesBackAHalfDoneEditAndKeepsTheHistory() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let tab = f.vm.activeDocument!
        try Pdfs.retitle(tab.session, "First")
        try tab.commit("Properties")

        _ = try AutoTagger.tag(tab.document)
        try tab.session.discard()

        XCTAssertFalse(try tab.commit("Add tags"))
        XCTAssertFalse(tab.document.isTagged)
        XCTAssertEqual(DocumentMetadata.read(tab.document).title, "First")
        XCTAssertEqual(tab.session.undoLabel, "Properties")
    }

    // TagNode

    func test_theChildrenOfATagAreMadeWhenAskedFor() throws {
        let tree = try XCTUnwrap(StructureTree.read(tagged()))
        let roots = TagNode.roots(tree)

        let root = try XCTUnwrap(roots.first { $0.element?.children.isEmpty == false })

        XCTAssertEqual(root.children?.count, root.element?.children.count)
        XCTAssertEqual(root.label, TagLabels.of(root.element!, tree))
    }

    func test_aTagWithNoChildrenIsALeaf() throws {
        let tree = StructureTree.create(try PdfDocument.open(Pdfs.text()))
        try tree.add(nil, StructElement("P"))

        XCTAssertNil(TagNode.roots(tree)[0].children)
    }

    func test_moreThanTwoHundredChildrenEndInOneRowThatSaysHowManyAreLeft() throws {
        let tree = StructureTree.create(try PdfDocument.open(Pdfs.text()))
        let list = StructElement("L")
        try tree.add(nil, list)
        for _ in 0..<230 { try tree.add(list, StructElement("LI")) }

        let nodes = try XCTUnwrap(TagNode.roots(tree)[0].children)

        XCTAssertEqual(nodes.count, 201)
        XCTAssertTrue(nodes[200].isMore)
        XCTAssertEqual(nodes[200].label, "30 more")
        XCTAssertNil(nodes[200].children)
        XCTAssertFalse(nodes[199].isMore)
    }
}
