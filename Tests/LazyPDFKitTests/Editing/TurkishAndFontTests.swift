import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/TurkishAndFontTests.cs: the same cases, except that the PdfPig assertions
// (the last of the first, fourth, fifth and sixth) have no twin. Arial is EditFont here, which has the letters used.

final class TurkishAndFontTests: XCTestCase {
    func test_turkishLettersComeFromTheFontSourceAndAreReported() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET")
        let editor = PageEditor(session, 0, EditArialSource())
        let result = try editor.replaceText(try EditKit.find(session, "world"), "dünya ğışŞİ")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertFalse(result.substitutions.isEmpty)
        XCTAssertTrue(result.substitutions[0].characters.contains("ğ"))
        XCTAssertTrue(try EditKit.text(session).contains("Hello dünya ğışŞİ"))
    }

    func test_withoutAFontSourceTheEditIsRefusedAndNothingIsCommitted() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "world"), "ğ")
        XCTAssertFalse(result.done)
        XCTAssertEqual(result.problem, EditingText.noFont)
        XCTAssertFalse(session.canUndo)
        XCTAssertEqual(DotNetText.trim(try EditKit.text(session)), "Hello world")
    }

    func test_winAnsiLettersNeedNoSubstitution() throws {
        let session = try EditKit.session("BT /F1 12 Tf 50 700 Td (Hello world) Tj ET")
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "world"), "café")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(result.substitutions.isEmpty)
        XCTAssertTrue(try EditKit.text(session).contains("café"))
    }

    func test_aSubsetCidFontIsReusedForItsOwnLetters() throws {
        let session = try PdfEditSession.open(try EditFixtures.embeddedLine("Hello world"))
        let result = try PageEditor(session, 0, EditArialSource()).replaceText(try EditKit.find(session, "world"), "lower")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(result.substitutions.isEmpty)
        XCTAssertEqual(DotNetText.trim(try EditKit.text(session)), "Hello lower")
    }

    func test_aSubsetCidFontLackingALetterGetsAMatchingFont() throws {
        let session = try PdfEditSession.open(try EditFixtures.embeddedLine("Hello world"))
        let result = try PageEditor(session, 0, EditArialSource()).replaceText(try EditKit.find(session, "world"), "quizğ")
        XCTAssertTrue(result.done, result.problem ?? "")
        let sub = try assertSingle(result.substitutions)
        XCTAssertTrue(sub.characters.contains("q"))
        XCTAssertTrue(sub.embedded)
        XCTAssertTrue(try EditKit.text(session).contains("Hello quizğ"))
    }

    func test_aWholeEmbeddedFontTakesNewLettersThroughItsOwnCmap() throws {
        let session = try PdfEditSession.open(try EditFixtures.fullCidLine("Hello world"))
        let result = try PageEditor(session, 0).replaceText(try EditKit.find(session, "world"), "quiz ğş")
        XCTAssertTrue(result.done, result.problem ?? "")
        XCTAssertTrue(result.substitutions.isEmpty)
        XCTAssertTrue(try EditKit.text(session).contains("Hello quiz ğş"))
    }
}
