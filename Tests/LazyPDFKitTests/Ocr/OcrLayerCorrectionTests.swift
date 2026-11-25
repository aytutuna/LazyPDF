import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/OcrLayerCorrectionTests.cs: the same cases. The PdfPig reading of the saved files
// (ChangeSurvivesSavingAndReopening, CorrectedFileOpensInPdfPig) has no twin; CorrectedFileOpensInPdfPig reads the saved file
// with this engine's text page instead.

final class OcrLayerCorrectionTests: XCTestCase {
    private func withLayer(_ pageEntries: String = "") throws -> PdfDocument {
        let document = try OcrKit.scan(1, pageEntries)
        let geometry = PageGeometry(document.pages[0])
        _ = try PdfOcrLayer.add(document, [OcrPageWords(0, OcrKit.words(), Int(geometry.width), Int(geometry.height))], "en-US")
        return document
    }

    private func fontOf(_ document: PdfDocument) -> PdfReference? {
        document.dict(document.pages[0].resources, "Font")?["LPOcrF"] as? PdfReference
    }

    private func texts(_ document: PdfDocument) throws -> [String] {
        OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0]))
    }

    func test_changedWordKeepsItsBox() throws {
        for rotate in [0, 90, 180, 270] {
            let document = try withLayer("/Rotate \(rotate)")
            try PdfOcrLayer.correct(document, document.pages[0], 1, "earth")

            let found = OcrKit.located(document)
            XCTAssertEqual(found.map { $0.text }, ["Hello", "earth", "Second", "line"], "rotate \(rotate)")
            let box = found[1].box
            XCTAssertTrue(abs(box.x - 160) < 1 && abs(box.y - 100) < 1 && abs(box.width - 110) < 1 && abs(box.height - 24) < 1, "rotate \(rotate): \(box)")
            XCTAssertEqual(OcrKit.layerStreams(document), 1)
        }
    }

    func test_changeSurvivesSavingAndReopening() throws {
        let document = try withLayer()
        try PdfOcrLayer.correct(document, document.pages[0], 2, "Third")
        let file = try document.saveRewrite()
        let reopened = try PdfDocument.open(file)
        XCTAssertEqual(OcrKit.located(reopened).map { $0.text }, ["Hello", "world", "Third", "line"])

        try PdfOcrLayer.correct(reopened, reopened.pages[0], 0, "Hi")
        let again = try PdfDocument.open(try reopened.saveIncremental())
        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(again, again.pages[0])), ["Hi", "world", "Third", "line"])
    }

    func test_repeatedChangesDoNotMoveTheBox() throws {
        let document = try withLayer()
        let before = try PdfOcrLayer.words(document, document.pages[0])[3].box
        for i in 0..<20 { try PdfOcrLayer.correct(document, document.pages[0], 3, i % 2 == 0 ? "lines" : "line") }
        let after = try PdfOcrLayer.words(document, document.pages[0])[3].box
        XCTAssertTrue(abs(before.x - after.x) < 0.001 && abs(before.width - after.width) < 0.001 && abs(before.y - after.y) < 0.001)
    }

    func test_emptyTextRemovesTheWordAndAnEmptiedLine() throws {
        let document = try withLayer()
        try PdfOcrLayer.correct(document, document.pages[0], 1, "  ")
        XCTAssertEqual(try texts(document), ["Hello", "Second", "line"])
        try PdfOcrLayer.correct(document, document.pages[0], 0, "")
        try PdfOcrLayer.correct(document, document.pages[0], 0, "")
        try PdfOcrLayer.correct(document, document.pages[0], 0, "")
        XCTAssertTrue(try texts(document).isEmpty)
        XCTAssertTrue(TextPage.create(document, document.pages[0]).words.isEmpty)
    }

    func test_fontIsKeptForPlainTextAndReplacedForANewWideCharacter() throws {
        let document = try withLayer()
        let font = try XCTUnwrap(fontOf(document))
        try PdfOcrLayer.correct(document, document.pages[0], 0, "ğüşİı")
        XCTAssertEqual(fontOf(document), font)

        let wide = "\u{1F600}"
        try PdfOcrLayer.correct(document, document.pages[0], 1, wide)
        XCTAssertNotEqual(fontOf(document), font)
        let second = fontOf(document)
        XCTAssertEqual(TextPage.create(document, document.pages[0]).words.map { $0.text }, ["ğüşİı", wide, "Second", "line"])

        // The font already has the character now, and another word may use it too.
        try PdfOcrLayer.correct(document, document.pages[0], 2, wide + wide)
        XCTAssertEqual(fontOf(document), second)
        XCTAssertEqual(try texts(document), ["ğüşİı", wide, wide + wide, "line"])
    }

    func test_wideCharactersOfOtherWordsKeepTheirCodesWhenTheFontIsReplaced() throws {
        let document = try OcrKit.scan()
        let a = "\u{20000}", b = "\u{1F600}", c = "\u{1F601}"
        _ = try PdfOcrLayer.add(document, [OcrPageWords(0, [OcrKit.word(a, 10, 10, 40, 20), OcrKit.word(b, 60, 10, 40, 20), OcrKit.word("x", 110, 10, 40, 20)], 400, 600)], "en")
        try PdfOcrLayer.correct(document, document.pages[0], 2, c)
        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(TextPage.create(reopened, reopened.pages[0]).words.map { $0.text }, [a, b, c])
    }

    func test_duplicatedPageKeepsItsOwnWordsWhenTheOtherIsChangedOrLosesItsLayer() throws {
        let document = try withLayer()
        try PageOperations.duplicate(document, [0])
        try PdfOcrLayer.correct(document, document.pages[0], 0, "\u{20000}")
        XCTAssertEqual(try PdfOcrLayer.words(document, document.pages[0])[0].text, "\u{20000}")
        XCTAssertEqual(try PdfOcrLayer.words(document, document.pages[1])[0].text, "Hello")
        XCTAssertEqual(TextPage.create(document, document.pages[1]).words[0].text, "Hello")

        PdfOcrLayer.remove(document, document.pages[0])
        XCTAssertFalse(PdfOcrLayer.has(document, document.pages[0]))
        XCTAssertEqual(TextPage.create(document, document.pages[1]).words.map { $0.text }, ["Hello", "world", "Second", "line"])
    }

    func test_noSuchWordOrNoLayerThrows() throws {
        let document = try withLayer()
        XCTAssertThrowsError(try PdfOcrLayer.correct(document, document.pages[0], 4, "x")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }
        XCTAssertThrowsError(try PdfOcrLayer.correct(document, document.pages[0], -1, "x")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }
        let bare = try OcrKit.scan()
        XCTAssertThrowsError(try PdfOcrLayer.correct(bare, bare.pages[0], 0, "x")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }
        XCTAssertEqual(try texts(document), ["Hello", "world", "Second", "line"])
    }

    func test_correctedFileOpensInPdfPig() throws {
        let document = try withLayer("/Rotate 90")
        try PdfOcrLayer.correct(document, document.pages[0], 0, "\u{20000}")
        try PdfOcrLayer.correct(document, document.pages[0], 1, "Welt")
        let reopened = try PdfDocument.open(try document.saveRewrite())
        let words = TextPage.create(reopened, reopened.pages[0]).words.map { $0.text }
        XCTAssertTrue(words.contains("Welt"))
        XCTAssertTrue(words.contains("Second") && words.contains("line"))
    }

    func test_aLayerStreamNextToAnotherKeepsItsWideCharactersWhenTheFontIsReplaced() throws {
        let document = try OcrKit.scan()
        let a = "\u{1F600}", b = "\u{20000}", c = "\u{1F601}"
        _ = try PdfOcrLayer.add(document, [OcrPageWords(0, [OcrKit.word(a, 10, 10, 40, 20)], 400, 600), OcrPageWords(0, [OcrKit.word(b, 10, 100, 40, 20)], 400, 600)], "en")
        XCTAssertEqual(OcrKit.layerStreams(document), 2)
        XCTAssertEqual(try texts(document), [b, a])

        try PdfOcrLayer.correct(document, document.pages[0], 1, c)

        XCTAssertEqual(try texts(document), [b, c])
    }

    func test_wordNumbersAtTheEdgesOfTheIntegersThrow() throws {
        let document = try withLayer()
        XCTAssertThrowsError(try PdfOcrLayer.correct(document, document.pages[0], Int.max, "x")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }
        XCTAssertThrowsError(try PdfOcrLayer.correct(document, document.pages[0], Int.min, "x")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }
    }
}
