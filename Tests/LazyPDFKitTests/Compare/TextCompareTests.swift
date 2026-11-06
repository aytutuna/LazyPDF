import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/TextCompareTests.cs: the same cases.

final class TextCompareTests: CompareTestCase {
    private lazy var base: [[String]] = [page("one"), page("two"), page("three")]

    private func with(_ page: Int, _ line: Int, _ text: String) -> [[String]] {
        var copy = base
        copy[page][line] = text
        return copy
    }

    func test_identicalFilesHaveNoChanges() throws {
        let result = try compare(base, base)
        XCTAssertTrue(result.isIdentical)
        XCTAssertEqual(result.summary.total, 0)
        for p in result.pages { XCTAssertEqual(p.similarity, 1.0) }
        XCTAssertEqual(result.pages.count, 3)
    }

    func test_oneChangedWordIsOneChangeWithQuadsOnBothSides() throws {
        let after = with(1, 2, "two line3 two3w1 two3w2 CHANGED two3w4 two3w5 two3w6 two3w7 two3w8")
        let change = try single(try compare(base, after).changes)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.area, .text)
        XCTAssertEqual(change.oldPage, 1)
        XCTAssertEqual(change.newPage, 1)
        XCTAssertEqual(change.oldText, "two3w3")
        XCTAssertEqual(change.newText, "CHANGED")
        let old = try single(change.oldQuads)
        let now = try single(change.newQuads)
        // Line 3 of a page has its baseline at y = 700.
        assertInRange(old.bounds.bottom, 695, 705)
        assertInRange(now.bounds.bottom, 695, 705)
        XCTAssertTrue(now.bounds.width > old.bounds.width)
    }

    func test_addedWordsHaveAnAnchorOnTheOldSide() throws {
        let after = with(0, 0, "one line1 one1w1 one1w2 NEW WORDS one1w3 one1w4 one1w5 one1w6 one1w7 one1w8")
        let result = try compare(base, after)
        let change = try single(result.changes)
        XCTAssertEqual(change.kind, .added)
        XCTAssertEqual(change.newText, "NEW WORDS")
        XCTAssertEqual(change.oldText, "")
        let anchor = try single(change.oldQuads)
        XCTAssertEqual(anchor.bounds.width, 0, accuracy: 1e-6)
        XCTAssertTrue(anchor.bounds.height > 5)
        XCTAssertEqual(result.summary.wordsAdded, 2)
    }

    func test_removedWordsHaveAnAnchorOnTheNewSide() throws {
        let after = with(2, 4, "three line5 three5w1 three5w2 three5w7 three5w8")
        let change = try single(try compare(base, after).changes)
        XCTAssertEqual(change.kind, .removed)
        XCTAssertEqual(change.oldText, "three5w3 three5w4 three5w5 three5w6")
        XCTAssertEqual(try single(change.newQuads).bounds.width, 0, accuracy: 1e-6)
        _ = try single(change.oldQuads)
    }

    func test_separateEditsAreSeparateChanges() throws {
        let after = with(0, 0, "one line1 X one1w2 one1w3 one1w4 one1w5 one1w6 one1w7 Y")
        let result = try compare(base, after)
        XCTAssertEqual(result.changes.count, 2)
        XCTAssertEqual(result.changes.map { $0.newText }, ["X", "Y"])
    }

    func test_movedParagraphIsOneMovedChange() throws {
        let lines = (1...8).map { i in "paragraph\(i) " + (1...9).map { k in "p\(i)x\(k)" }.joined(separator: " ") }
        let moved = [lines[0], lines[1], lines[5], lines[2], lines[3], lines[4], lines[6], lines[7]]
        let result = try compare([lines], [moved])
        let change = try single(result.changes)
        XCTAssertEqual(change.kind, .moved)
        XCTAssertEqual(change.oldText, lines[5])
        XCTAssertEqual(change.newText, lines[5])
        assertInRange(try single(change.oldQuads).bounds.bottom, 635, 645)
        assertInRange(try single(change.newQuads).bounds.bottom, 695, 705)
        XCTAssertEqual(result.summary.moved, 1)
        XCTAssertEqual(result.summary.wordsAdded, 0)
    }

    func test_paragraphMovedToAnotherPageIsMoved() throws {
        let first = page("first", 7), second = page("second", 7)
        let before = [first, second]
        let after = [Array(first[0..<3]) + Array(first[4...]), second + [first[3]]]
        let change = try single(try compare(before, after).changes)
        XCTAssertEqual(change.kind, .moved)
        XCTAssertEqual(change.oldPage, 0)
        XCTAssertEqual(change.newPage, 1)
    }

    func test_changedBlockIsNotAMove() throws {
        let lines = page("block", 6)
        var edited = lines
        edited[2] = "block line3 something else entirely different here now"
        let result = try compare([lines], [edited])
        XCTAssertEqual(try single(result.changes).kind, .changed)
    }

    func test_caseDiffersUnlessIgnored() throws {
        let after = with(0, 1, "one line2 ONE2W1 one2w2 one2w3 one2w4 one2w5 one2w6 one2w7 one2w8")
        let change = try single(try compare(base, after).changes)
        XCTAssertEqual(change.oldText, "one2w1")
        XCTAssertTrue(try compare(base, after, CompareOptions(ignoreCase: true)).isIdentical)
    }

    func test_splitAndJoinedWordsAreEqualWhenWhiteSpaceIsIgnored() throws {
        let before = [["the data base of the system is large enough"]]
        let after = [["the database of the system is large enough"]]
        _ = try single(try compare(before, after).changes)
        XCTAssertTrue(try compare(before, after, CompareOptions(ignoreWhiteSpace: true)).isIdentical)
    }

    func test_whiteSpaceOptionStillSeesRealChanges() throws {
        let before = [["the data base of the system is large enough"]]
        let after = [["the database of the system is small enough"]]
        let change = try single(try compare(before, after, CompareOptions(ignoreWhiteSpace: true)).changes)
        XCTAssertEqual(change.newText, "small")
    }

    func test_headerAndFooterZonesCanBeIgnored() throws {
        // The header sits at y = 770 and the footer at y = 20 on a 792 point page.
        func make(_ header: String, _ footer: String) throws -> PdfDocument {
            let pdf = TestPdf()
            pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>")
            pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
            pdf.stream(4, "", "BT /F1 12 Tf 72 770 Td (\(header)) Tj ET BT /F1 12 Tf 72 400 Td (body text of the page) Tj ET BT /F1 12 Tf 72 20 Td (\(footer)) Tj ET")
            pdf.obj(5, ContentTestPdf.helvetica)
            return try open(pdf.finish())
        }
        let a = try make("Report May", "Page 1")
        let b = try make("Report June", "Page 2")
        XCTAssertEqual(try compare(a, b).changes.count, 2)
        XCTAssertTrue(try compare(a, b, CompareOptions(ignoreHeaderFooter: true)).isIdentical)
    }

    func test_bodyTextIsKeptWhenHeaderAndFooterAreIgnored() throws {
        let after = with(0, 2, "one line3 one3w1 one3w2 one3w3 BODY one3w5 one3w6 one3w7 one3w8")
        let result = try compare(base, after, CompareOptions(ignoreHeaderFooter: true))
        XCTAssertEqual(try single(result.changes).newText, "BODY")
    }

    func test_halfTheWordsDifferingGivesTheirCount() throws {
        let a = page("keep", 15) + (0..<15).map { i in (0..<9).map { k in "a\(i)x\(k)" }.joined(separator: " ") }
        let b = page("keep", 15) + (0..<15).map { i in (0..<9).map { k in "b\(i)x\(k)" }.joined(separator: " ") }
        let result = try compare([a], [b])
        XCTAssertEqual(result.summary.wordsAdded, 135)
        XCTAssertEqual(result.summary.wordsRemoved, 135)
        XCTAssertEqual(try single(result.changes).kind, .changed)
    }

    func test_pagesWithNothingInCommonAreRemovedAndAdded() throws {
        let result = try compare([page("aaa")], [page("bbb")])
        XCTAssertEqual(result.changes.map { $0.kind.rawValue }.sorted(), [ChangeKind.added.rawValue, ChangeKind.removed.rawValue])
        for c in result.changes { XCTAssertEqual(c.area, .page) }
    }
}
