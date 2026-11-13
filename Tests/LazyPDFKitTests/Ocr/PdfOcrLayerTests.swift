import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/PdfOcrLayerTests.cs: the same cases. The C# also reads the saved files with
// PdfPig (FileReopensAndPdfPigReadsTheWords, CharactersBeyondTheBmpAndTurkishLettersSurvive); those assertions have no twin.
// A lone U+D800 cannot be a Swift string, so BadWordsAreLeftOut gives the U+FFFD it becomes.

final class PdfOcrLayerTests: XCTestCase {
    @discardableResult
    private func addWords(_ document: PdfDocument, _ words: [OcrWord], _ width: Int = 400, _ height: Int = 600, _ pageIndex: Int = 0) throws -> Int {
        try PdfOcrLayer.add(document, [OcrPageWords(pageIndex, words, width, height)], "en-US")
    }

    private func fontEntry(_ document: PdfDocument, _ pageIndex: Int, _ name: String) -> PdfDictionary? {
        document.dict(document.dict(document.pages[pageIndex].resources, "Font"), name)
    }

    func test_wordsSitOnTheirBoxesOnTheShownPage() throws {
        for rotate in [0, 90, 180, 270] {
            let document = try OcrKit.scan(1, "/Rotate \(rotate)")
            let geometry = PageGeometry(document.pages[0])
            XCTAssertEqual(geometry.width, rotate == 90 || rotate == 270 ? 600 : 400, "rotate \(rotate)")
            try addWords(document, OcrKit.words(), Int(geometry.width), Int(geometry.height))
            OcrKit.assertAtBoxes(document)
        }
    }

    func test_skewedLineIsWrittenWithTurnedTextMatrices() throws {
        let document = try OcrKit.scan()
        let angle = 0.1
        try addWords(document, [OcrWord("Skewed", OcrBox(50, 100, 100, 20), 1, angle), OcrWord("line", OcrBox(160, 100, 60, 20), 1, angle)])
        let page = document.pages[0]
        let tokens = OcrKit.latin(page.contents()).split(whereSeparator: { $0 == " " || $0.isNewline }).map(String.init)
        var matrices: [[Double]] = []
        for (i, token) in tokens.enumerated() where token == "Tm" && i >= 6 {
            matrices.append(tokens[(i - 6)..<i].map { Double($0) ?? .nan })
        }
        XCTAssertEqual(matrices.count, 3)
        for m in matrices {
            XCTAssertEqual(m[0], cos(angle), accuracy: 1e-4)
            XCTAssertEqual(m[1], sin(angle), accuracy: 1e-4)
            XCTAssertEqual(m[2], -sin(angle), accuracy: 1e-4)
            XCTAssertEqual(m[3], cos(angle), accuracy: 1e-4)
        }
        XCTAssertEqual(matrices[0][4], 50, accuracy: 1e-3)
        XCTAssertEqual(matrices[0][5], 600 - 120, accuracy: 1e-3)

        let layer = try PdfOcrLayer.words(document, page)
        XCTAssertEqual(layer.map { $0.text }, ["Skewed", "line"])
        XCTAssertEqual(layer[0].box.x, 48.003, accuracy: 1e-3)
        XCTAssertEqual(layer[0].box.y, 90.117, accuracy: 1e-3)
        XCTAssertEqual(layer[0].box.width, 101.497, accuracy: 1e-3)
        XCTAssertEqual(layer[0].box.height, 29.883, accuracy: 1e-3)

        try PdfOcrLayer.correct(document, page, 1, "lane")
        XCTAssertTrue(OcrKit.latin(page.contents()).contains("0.995"))
        XCTAssertEqual(try PdfOcrLayer.words(document, page).map { $0.text }, ["Skewed", "lane"])
    }

    func test_straightLineIsWrittenAsBefore() throws {
        let a = try OcrKit.scan(), b = try OcrKit.scan()
        try addWords(a, [OcrWord("Same", OcrBox(50, 100, 100, 20)), OcrWord("here", OcrBox(160, 102, 60, 18))])
        try addWords(b, [OcrWord("Same", OcrBox(50, 100, 100, 20), 1, 0), OcrWord("here", OcrBox(160, 102, 60, 18), 1, .nan)])
        XCTAssertEqual(OcrKit.latin(a.pages[0].contents()), OcrKit.latin(b.pages[0].contents()))
    }

    func test_pictureSizeScalesTheBoxes() throws {
        let document = try OcrKit.scan()
        try addWords(document, OcrKit.words(dpi: 300), 400 * 300 / 72, 600 * 300 / 72)
        OcrKit.assertAtBoxes(document)
    }

    func test_fileReopensAndPdfPigReadsTheWords() throws {
        for rotate in [0, 90, 180, 270] {
            let document = try OcrKit.scan(1, "/Rotate \(rotate)")
            let geometry = PageGeometry(document.pages[0])
            try addWords(document, OcrKit.words(), Int(geometry.width), Int(geometry.height))

            let files = [try document.saveRewrite(), try document.saveRewrite(PdfSaveOptions(useObjectStreams: true)), try document.saveIncremental()]
            for file in files {
                let reopened = try PdfDocument.open(file)
                XCTAssertTrue(PdfOcrLayer.has(reopened, reopened.pages[0]), "rotate \(rotate)")
                OcrKit.assertAtBoxes(reopened)
            }
        }
    }

    func test_layerIsInvisibleTextInAGlyphlessFontAndKeepsTheStateOfThePage() throws {
        let document = try OcrKit.scan()
        try addWords(document, OcrKit.words())
        let page = document.pages[0]
        let content = OcrKit.latin(page.contents())
        XCTAssertTrue(content.hasPrefix("q\n"))
        XCTAssertTrue(content.contains("3 Tr"))
        XCTAssertTrue(content.hasSuffix("/Im1 Do Q"))
        XCTAssertEqual(OcrKit.layerStreams(document), 1)

        let entry = try XCTUnwrap(fontEntry(document, 0, "LPOcrF"))
        let font = PdfFont.get(document, entry)
        XCTAssertTrue(font.isComposite)
        XCTAssertTrue(font.isEmbedded)
        XCTAssertTrue(font.hasToUnicode)
        let drawn = Recorder()
        ContentInterpreter(document).run(page, drawn)
        XCTAssertEqual(drawn.images.count, 1)
        XCTAssertTrue(drawn.renderModes.allSatisfy { $0 == 3 })
        XCTAssertTrue(drawn.text.contains("Hello world"), drawn.text)
    }

    func test_addTwiceLeavesOneLayerWithTheNewWords() throws {
        let document = try OcrKit.scan()
        try addWords(document, OcrKit.words())
        try addWords(document, [OcrKit.word("Only", 40, 100, 80, 24)])
        XCTAssertEqual(OcrKit.layerStreams(document), 1)
        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0])), ["Only"])
        XCTAssertNotNil(fontEntry(document, 0, "LPOcrF"))
    }

    func test_nothingRecognizedLeavesNoLayer() throws {
        let document = try OcrKit.scan()
        try addWords(document, OcrKit.words())
        XCTAssertEqual(try addWords(document, []), 0)
        XCTAssertFalse(PdfOcrLayer.has(document, document.pages[0]))
        XCTAssertNil(fontEntry(document, 0, "LPOcrF"))
        XCTAssertEqual(OcrKit.latin(document.pages[0].contents()), "q 400 0 0 600 0 0 cm /Im1 Do Q")
    }

    func test_removeTakesTheLayerAndFontAwayAndLeavesOthersAlone() throws {
        let document = try OcrKit.pages("BT /F1 12 Tf 50 500 Td (Printed) Tj ET")
        try addWords(document, OcrKit.words())
        XCTAssertTrue(PdfOcrLayer.remove(document, document.pages[0]))
        XCTAssertFalse(PdfOcrLayer.remove(document, document.pages[0]))
        XCTAssertEqual(TextPage.create(document, document.pages[0]).words.map { $0.text }, ["Printed"])
        XCTAssertNotNil(fontEntry(document, 0, "F1"))
    }

    func test_layerGoesFirstAndWorksWithUnbalancedPageContent() throws {
        let document = try OcrKit.pages("q q BT /F1 12 Tf 50 500 Td (Printed) Tj ET Q Q Q 1 0 0 rg")
        try addWords(document, OcrKit.words())
        let texts = TextPage.create(document, document.pages[0]).words.map { $0.text }
        XCTAssertTrue(texts.contains("Printed"))
        XCTAssertTrue(texts.contains("Hello"))
        let printed = Recorder()
        ContentInterpreter(document).run(document.pages[0], printed)
        XCTAssertTrue(printed.glyphs.contains { $0.unicode == "P" })
    }

    func test_sharedResourcesAreNotChangedForOtherPages() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 400 600]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 7 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources 7 0 R>>")
        pdf.stream(5, "", "q Q")
        pdf.obj(6, OcrKit.helvetica)
        pdf.obj(7, "<</Font <</F1 6 0 R>>>>")
        let document = try PdfDocument.open(pdf.finish())
        try addWords(document, OcrKit.words())
        XCTAssertTrue(PdfOcrLayer.has(document, document.pages[0]))
        XCTAssertFalse(PdfOcrLayer.has(document, document.pages[1]))
        XCTAssertNil(fontEntry(document, 1, "LPOcrF"))
        XCTAssertNotNil(fontEntry(document, 0, "F1"))
    }

    func test_pageWithoutContentsOrWithInheritedResourcesTakesALayer() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 400 600] /Resources <</Font <</F1 4 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R>>")
        pdf.obj(4, OcrKit.helvetica)
        let document = try PdfDocument.open(pdf.finish())
        try addWords(document, OcrKit.words())
        let reopened = try PdfDocument.open(try document.saveRewrite())
        OcrKit.assertAtBoxes(reopened)
        XCTAssertNotNil(fontEntry(reopened, 0, "F1"))
    }

    func test_charactersBeyondTheBmpAndTurkishLettersSurvive() throws {
        let document = try OcrKit.scan()
        let wide = "\u{20000}\u{1F600}"
        try addWords(document, [OcrKit.word("ğüşİıÖ", 40, 100, 120, 24), OcrKit.word(wide, 180, 100, 60, 24), OcrKit.word("\u{20000}\u{20001}", 260, 100, 60, 24)])
        let expected = ["ğüşİıÖ", wide, "\u{20000}\u{20001}"]
        XCTAssertEqual(TextPage.create(document, document.pages[0]).words.map { $0.text }, expected)
        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0])), expected)

        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(TextPage.create(reopened, reopened.pages[0]).words.map { $0.text }, expected)
    }

    func test_rightToLeftWordsReadInLogicalOrderBack() throws {
        let document = try OcrKit.scan()
        // The recognizer reports the first word of a Hebrew line at the right.
        try addWords(document, [OcrKit.word("שלום", 250, 100, 80, 24), OcrKit.word("עולם", 150, 100, 80, 24),
                                OcrKit.word("مرحبا", 250, 160, 80, 24), OcrKit.word("بالعالم", 140, 160, 90, 24)])
        let page = TextPage.create(document, document.pages[0])
        XCTAssertEqual(page.text.trimmingCharacters(in: .whitespacesAndNewlines), "שלום עולם\nمرحبا بالعالم")
        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0])).sorted(), ["שלום", "עולם", "مرحبا", "بالعالم"].sorted())
        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(TextPage.create(reopened, reopened.pages[0]).text, page.text)
    }

    func test_numbersInsideAnRightToLeftWordKeepTheirOrder() throws {
        let document = try OcrKit.scan()
        try addWords(document, [OcrKit.word("סעיף3.14", 200, 100, 100, 24), OcrKit.word("(שלום)", 80, 100, 100, 24)])
        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0])).sorted(), ["(שלום)", "סעיף3.14"].sorted())
        XCTAssertEqual(TextPage.create(document, document.pages[0]).text.trimmingCharacters(in: .whitespacesAndNewlines), "סעיף3.14 (שלום)")
    }

    func test_badWordsAreLeftOut() throws {
        let document = try OcrKit.scan()
        let bad = [
            OcrKit.word("", 10, 10, 50, 20), OcrKit.word("   ", 10, 40, 50, 20), OcrKit.word("nan", Double.nan, 10, 50, 20),
            OcrKit.word("inf", 10, 10, Double.infinity, 20), OcrKit.word("flat", 10, 10, 50, 0), OcrKit.word("back", 10, 10, -50, 20),
            OcrKit.word("a\u{0}b\tc\n", 100, 200, 60, 20), OcrKit.word("\u{FFFD}", 200, 200, 40, 20), OcrKit.word("outside", -500, 5000, 50, 20),
        ]
        XCTAssertEqual(try addWords(document, bad), 3)
        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0])).sorted(), ["a b c", "\u{FFFD}", "outside"].sorted())
        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertTrue(PdfOcrLayer.has(reopened, reopened.pages[0]))
    }

    func test_wordsPastTheCapAreIgnored() throws {
        let document = try OcrKit.scan()
        let many = (0..<(PdfOcrLayer.maxWords + 500)).map { (i: Int) -> OcrWord in
            let x = 4 + i % 40 * 9, y = 4 + i / 40 % 100 * 5
            return OcrKit.word("w\(i)", Double(x), Double(y), 8, 4)
        }
        XCTAssertEqual(try addWords(document, many), PdfOcrLayer.maxWords)
    }

    func test_badArgumentsThrowBeforeAnythingChanges() throws {
        let document = try OcrKit.scan()
        XCTAssertThrowsError(try PdfOcrLayer.add(document, [OcrPageWords(0, OcrKit.words(), 0, 600)], "en")) { XCTAssertTrue($0 is ArgumentException, "\($0)") }
        XCTAssertThrowsError(try PdfOcrLayer.add(document, [OcrPageWords(0, OcrKit.words(), 400, 600), OcrPageWords(3, [], 400, 600)], "en")) {
            XCTAssertTrue($0 is ArgumentException, "\($0)")
        }
        XCTAssertFalse(PdfOcrLayer.has(document, document.pages[0]))
        XCTAssertFalse(document.hasChanges && OcrKit.layerStreams(document) > 0)
    }

    func test_layerOfAnotherToolIsNotFoundOrRemoved() throws {
        let document = try OcrKit.pages("BT 3 Tr /F1 12 Tf 50 500 Td (Other) Tj ET")
        XCTAssertFalse(PdfOcrLayer.has(document, document.pages[0]))
        XCTAssertFalse(PdfOcrLayer.remove(document, document.pages[0]))
        XCTAssertTrue(try PdfOcrLayer.words(document, document.pages[0]).isEmpty)
        XCTAssertNil(PdfOcrLayer.language(document, document.pages[0]))
    }

    func test_languageIsKept() throws {
        let document = try OcrKit.scan()
        _ = try PdfOcrLayer.add(document, [OcrPageWords(0, OcrKit.words(), 400, 600)], "tr-TR")
        let reopened = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(PdfOcrLayer.language(reopened, reopened.pages[0]), "tr-TR")
    }

    func test_userUnitAndCropBoxKeepTheBoxes() throws {
        let document = try OcrKit.scan(1, "/CropBox [20 30 380 570] /UserUnit 2")
        let geometry = PageGeometry(document.pages[0])
        XCTAssertEqual(geometry.width, 720)
        XCTAssertEqual(geometry.height, 1080)
        try addWords(document, OcrKit.words(), 720, 1080)
        OcrKit.assertAtBoxes(document)
    }

    // The C# throws InvalidOperationException from PdfDocument.Add; this port throws the read error there.
    func test_addThatCannotAddObjectsLeavesTheOldLayerAlone() throws {
        let document = try OcrKit.scan()
        try addWords(document, OcrKit.words())
        document.set(PdfDocument.maxObjectNumber, PdfNull.instance)

        XCTAssertThrowsError(try addWords(document, [OcrKit.word("other", 10, 10, 50, 20)])) { XCTAssertTrue($0 is PdfReadException, "\($0)") }

        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0])), ["Hello", "world", "Second", "line"])
        XCTAssertEqual(OcrKit.layerStreams(document), 1)
    }

    func test_aLayerWithMoreOperationsThanTheFormatCanHoldIsAReadError() throws {
        let document = try OcrKit.scan()
        try OcrKit.addLayer(document, String(repeating: "BT\n", count: 8 * PdfOcrLayer.maxWords + 2))

        XCTAssertThrowsError(try PdfOcrLayer.words(document, document.pages[0])) { XCTAssertTrue($0 is PdfReadException, "\($0)") }
    }

    func test_aLayerWithMoreWordsThanMaxWordsIsReadUpToMaxWords() throws {
        let document = try OcrKit.scan()
        try OcrKit.addLayer(document, "BT\n/LPOcrF 12 Tf\n" + String(repeating: "1 0 0 1 0 0 Tm\n<0041> Tj\n", count: PdfOcrLayer.maxWords + 1) + "ET\n")

        XCTAssertEqual(try PdfOcrLayer.words(document, document.pages[0]).count, PdfOcrLayer.maxWords)
    }

    func test_aLayerStreamThatDoesNotDecodeIsAReadError() throws {
        let document = try OcrKit.scan()
        let dictionary = PdfDictionary()
        dictionary["LazyPDFOcr"] = PdfDictionary()
        dictionary["Filter"] = PdfName("FlateDecode")
        let stream = try document.add(PdfStream(dictionary, data: [1, 2, 3, 4, 5]))
        document.pages[0].dictionary["Contents"] = PdfArray([stream])

        XCTAssertThrowsError(try PdfOcrLayer.words(document, document.pages[0])) { XCTAssertTrue($0 is PdfReadException, "\($0)") }
    }

    // A lone surrogate cannot be a Swift string, so a string the C# reads as one gives U+FFFD here.
    func test_aLoneSurrogateInAHandMadeLayerReadsAsTheReplacementCharacter() throws {
        let document = try OcrKit.scan()
        try OcrKit.addLayer(document, "BT\n/LPOcrF 24 Tf\n1 0 0 1 40 100 Tm\n<D800> Tj\n<0041D800> Tj\nET\n")

        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(document, document.pages[0])), ["\u{FFFD}", "A\u{FFFD}"])
    }
}
