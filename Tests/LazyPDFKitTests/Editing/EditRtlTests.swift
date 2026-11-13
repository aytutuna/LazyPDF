import Foundation
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/EditRtlTests.cs.

final class EditRtlTests: XCTestCase {
    private final class ScriptFonts: FontSource {
        static let font: [UInt8] = (try? ShapingGolden.font()) ?? []
        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(Self.font) }
    }

    private let fonts = ScriptFonts()

    // A page with the text set by the box writer: a Hebrew line is drawn in display order against the right edge of the box.
    private func page(_ text: String, width: Double = 200) throws -> PdfEditSession {
        let first = try PdfEditSession.open(try AnnotationFixtures.blank(1).saveRewrite())
        let added = try PageEditor(first, 0, fonts).addTextBox(PdfRect(50, 600, 50 + width, 700), text, TextBoxStyle(family: "Script Sans", size: 14))
        XCTAssertTrue(added.done)
        return try PdfEditSession.open(first.current)
    }

    private func read(_ session: PdfEditSession) throws -> TextPage {
        let document = try PdfDocument.open(session.current)
        return TextPage.create(document, document.pages[0])
    }

    private func extent(_ session: PdfEditSession) throws -> (left: Double, right: Double) {
        let chars = try read(session).chars.filter { !$0.isSpace }
        return (chars.map { $0.quad.bounds.left }.min()!, chars.map { $0.quad.bounds.right }.max()!)
    }

    private func block(_ editor: PageEditor) throws -> TextObject {
        let blocks = try editor.objects.compactMap { $0 as? TextObject }
        XCTAssertEqual(blocks.count, 1)
        return blocks[0]
    }

    func test_aLoneHebrewLineIsReadAsRightAligned() throws {
        XCTAssertEqual(try block(try PageEditor(try page("אבג דהו"), 0, fonts)).alignment, .right)
    }

    func test_aLatinLineStaysLeftAligned() throws {
        XCTAssertEqual(try block(try PageEditor(try page("abc def"), 0, fonts)).alignment, .left)
    }

    func test_replacingAWholeHebrewLineKeepsItsRightEdge() throws {
        for text in ["אב", "אבג דהו זחט יכל"] {
            let session = try page("אבג דהו")
            let right = try extent(session).right
            let editor = try PageEditor(session, 0, fonts)
            XCTAssertTrue(try editor.replaceText(try block(editor).range, text).done)
            XCTAssertEqual(try read(session).text.trimmingCharacters(in: .whitespacesAndNewlines), text)
            XCTAssertEqual(try extent(session).right, right, accuracy: 0.5)
        }
    }

    func test_replacingAHebrewLineInTwoColorsKeepsTheWordsInOrder() throws {
        let session = try page("אבג דהו")
        let red = RgbColor(255, 0, 0)
        let first = try PageEditor(session, 0, fonts)
        let old = try XCTUnwrap(try TextSearch.find(try read(session), "אבג", TextSearchOptions(matchCase: true)).first).range
        XCTAssertTrue(try first.setTextStyle([old], TextStyleChange(color: red)).done)
        let editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.replaceText(try block(editor).range, "זחט יכל").done)
        let now = try read(session)
        XCTAssertEqual(now.text.trimmingCharacters(in: .whitespacesAndNewlines), "זחט יכל")
        let word = try XCTUnwrap(try TextSearch.find(now, "זחט", TextSearchOptions(matchCase: true)).first).range
        for i in word.start..<word.end { XCTAssertEqual(now.chars[i].color, red) }
    }

    func test_replacingAHebrewWordStartsTheNewTextAtTheLeftEdgeOfTheOldOne() throws {
        let session = try page("אבג דהו")
        let old = try read(session)
        let word = try XCTUnwrap(try TextSearch.find(old, "אבג", TextSearchOptions(matchCase: true)).first).range
        let left = (word.start..<word.end).map { old.chars[$0].quad.bounds.left }.min()!
        let editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.replaceText(word, "זח").done)
        let now = try read(session)
        XCTAssertTrue(now.text.contains("זח"))
        let moved = try XCTUnwrap(try TextSearch.find(now, "זח", TextSearchOptions(matchCase: true)).first).range
        XCTAssertEqual((moved.start..<moved.end).map { now.chars[$0].quad.bounds.left }.min()!, left, accuracy: 0.5)
    }

    func test_replacingTheTextOfABlockKeepsItsRightEdge() throws {
        let session = try page("אבג דהו")
        let right = try extent(session).right
        let editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.replaceParagraph(try block(editor), "דהו אבג").done)
        XCTAssertEqual(try read(session).text.trimmingCharacters(in: .whitespacesAndNewlines), "דהו אבג")
        XCTAssertEqual(try extent(session).right, right, accuracy: 0.5)
    }

    func test_editedHebrewCanBeEditedAgain() throws {
        let session = try page("אבג דהו")
        let editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.replaceText(try block(editor).range, "זחט").done)
        let again = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try again.replaceText(try block(again).range, "יכל").done)
        XCTAssertEqual(try read(session).text.trimmingCharacters(in: .whitespacesAndNewlines), "יכל")
    }

    func test_mirroredBracketsInEditedHebrewCarryTheirActualText() throws {
        let session = try page("abc")
        let editor = try PageEditor(session, 0, fonts)
        XCTAssertTrue(try editor.replaceText(try block(editor).range, "אב (גד)").done)
        XCTAssertTrue(EditKit.latin(session).contains("/ActualText"))
        XCTAssertEqual(try read(session).text.trimmingCharacters(in: .whitespacesAndNewlines), "אב (גד)")
    }
}
