import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/ReplaceTextTests.cs: the same cases, except that the two assertions that
// PdfPig reads the new words back (ReplacesAWordInOneString, WordsOfATJArrayKeepTheirKerning) have no twin.

final class ReplaceTextTests: XCTestCase {
    private let line = "BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET"

    private func trimmed(_ text: String) -> String { DotNetText.trim(text) }

    func test_replacesAWordInOneString() throws {
        let session = try EditKit.session(line)
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertEqual(trimmed(try EditKit.text(session)), "Hello grand world")
        XCTAssertTrue(session.canUndo)
    }

    func test_aLongerWordMovesTheRestOfTheRunAndLeavesOtherRuns() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello brave) Tj 100 0 Td (tail) Tj ET")
        let before = try EditKit.glyphs(session)
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "braver and bolder")
        XCTAssertTrue(result.done, result.problem ?? "")
        let after = try EditKit.glyphs(session)
        XCTAssertEqual(after.prefix(23).map { $0.text }.joined(), "Hello braver and bolder")
        // The first glyph and the other run are where they were.
        XCTAssertEqual(before[0], after[0])
        XCTAssertEqual(before[before.count - 1], after[after.count - 1])
        XCTAssertTrue(result.overlaps)
    }

    func test_wordsOfATJArrayKeepTheirKerning() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td [(Hel) -120 (lo) 300 (wor) -50 (ld)] TJ ET")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "lo"), "p")
        XCTAssertTrue(result.done, result.problem ?? "")
        let content = EditKit.latin(session)
        XCTAssertTrue(content.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").contains("(Hel) -120 (p) 300 (wor) -50 (ld)"))
    }

    func test_deleteKeepsTheRestInPlace() throws {
        let session = try EditKit.session(line)
        let before = try EditKit.glyphs(session)
        let result = try PageEditor(session, 0).deleteText(try EditKit.find(session, "brave"))
        XCTAssertTrue(result.done, result.problem ?? "")
        let after = try EditKit.glyphs(session)
        XCTAssertEqual(after.map { $0.text }.joined(), "Hello  world")
        XCTAssertEqual(before[before.count - 1], after[after.count - 1])
        XCTAssertEqual(before[0], after[0])
    }

    func test_insertGoesBeforeTheCharacter() throws {
        let session = try EditKit.session(line)
        let text = TextPage.create(session.document, session.document.pages[0])
        let found = try XCTUnwrap(text.text.range(of: "world", options: .literal))
        let at = found.lowerBound.utf16Offset(in: text.text)
        let result = try PageEditor(session, 0).insertText(at, "big ")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertEqual(trimmed(try EditKit.text(session)), "Hello brave big world")
    }

    func test_operatorsOutsideTheEditKeepTheirBytes() throws {
        let content = "q 1 0 0 1 5 5 cm 0.5 g 10 10 100 100 re f Q\nBT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET\nq 2 w 0 0 m 50 50 l S Q"
        let session = try EditKit.session(content)
        _ = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
        let after = EditKit.latin(session)
        XCTAssertTrue(after.hasPrefix("q 1 0 0 1 5 5 cm 0.5 g 10 10 100 100 re f Q\nBT /F1 12 Tf 50 700 Td "))
        XCTAssertTrue(after.hasSuffix(" ET\nq 2 w 0 0 m 50 50 l S Q"))
    }

    func test_aRunThatStartsInsideTheCutKeepsItsTextWhereItWas() throws {
        // The word is in two text objects, the second going on with " code"; the new word goes in the first.
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Sou) Tj ET BT /F1 12 Tf 71.348 700 Td (rce code) Tj ET")
        let before = try EditKit.glyphs(session)
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "Source"), "ourceS")
        XCTAssertTrue(result.done, result.problem ?? "")
        let after = try EditKit.glyphs(session)
        XCTAssertEqual(after.map { $0.text }.joined(), "ourceS code")
        XCTAssertEqual(before.dropFirst(6).map { $0.text }, after.dropFirst(6).map { $0.text })
        XCTAssertEqual(before.dropFirst(6).map { $0.x }, after.dropFirst(6).map { $0.x })
    }

    func test_aWordInTwoSizesTakesItsNewLettersInTheSameSizes() throws {
        let session = try EditKit.session("BT /F1 24 Tf 50 700 Td (P) Tj /F1 12 Tf (RINTED) Tj ET")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "PRINTED"), "RINTEDP")
        XCTAssertTrue(result.done, result.problem ?? "")
        let glyphs = try EditKit.glyphs(session)
        XCTAssertEqual(glyphs.map { $0.text }.joined(), "RINTEDP")
        XCTAssertEqual(glyphs.map { $0.size }, [24, 12, 12, 12, 12, 12, 12])
        XCTAssertTrue(try EditKit.text(session).contains("RINTEDP"))
    }

    func test_undoBringsTheOldTextBack() throws {
        let session = try EditKit.session(line)
        _ = try PageEditor(session, 0).replaceText(try EditKit.find(session, "brave"), "grand")
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(trimmed(try EditKit.text(session)), "Hello brave world")
        XCTAssertTrue(try session.redo())
        XCTAssertEqual(trimmed(try EditKit.text(session)), "Hello grand world")
    }

    func test_insertBeforeTheFirstCharacterIsRefusedWhenThereIsNoCharacter() throws {
        let session = try EditKit.session(line)
        let result = try PageEditor(session, 0).insertText(-1, "X")
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.problem, EditingText.noText)
    }
}
