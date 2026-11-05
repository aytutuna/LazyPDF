import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/OcrTriageTests.cs: the same cases.

final class OcrTriageTests: XCTestCase {
    private func kindOf(_ document: PdfDocument, _ page: Int = 0) -> OcrPageKind {
        OcrTriage.classify(document, document.pages[page])
    }

    func test_kindsOfPages() throws {
        XCTAssertEqual(kindOf(try OcrKit.scan()), .picture)
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "")), .blank)
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "0 0 100 100 re f")), .drawing)
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "q 40 0 0 40 10 10 cm /Im1 Do Q")), .drawing)
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "BT /F1 12 Tf 50 500 Td (Hello) Tj ET")), .text)
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "q 400 0 0 600 0 0 cm /Im1 Do Q BT 3 Tr /F1 12 Tf 50 500 Td (Hello) Tj ET")), .foreignLayer)
    }

    func test_pictureWithAStampOfTextIsStillAPictureButTextBeneathItIsText() throws {
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "q 400 0 0 600 0 0 cm /Im1 Do Q BT /F1 8 Tf 10 10 Td (B 000123) Tj ET")), .picture)
        let lines = (0..<30).map { "BT /F1 14 Tf 20 \(550 - 18 * $0) Td (A line of printed words that fills the page) Tj ET " }.joined()
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "q 400 0 0 600 0 0 cm /Im1 Do Q " + lines)), .text)
    }

    func test_pictureShareIsOfTheCropBox() throws {
        let document = try OcrKit.scan(1, "/CropBox [0 0 200 300]", "q 200 0 0 300 0 0 cm /Im1 Do Q")
        XCTAssertEqual(kindOf(document), .picture)
        let half = try OcrKit.scan(1, "", "q 400 0 0 200 0 0 cm /Im1 Do Q")
        XCTAssertEqual(kindOf(half), .drawing)
    }

    func test_invisibleTextOfOtherToolsAndHiddenModesAreNotVisibleText() throws {
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "BT 7 Tr /F1 12 Tf 50 500 Td (Clip) Tj ET")), .blank)
        XCTAssertEqual(kindOf(try OcrKit.scan(1, "", "BT /F1 12 Tf 50 500 Td (   ) Tj ET")), .blank)
    }

    func test_ourOwnLayerIsRecognizedWhateverElseThePageShows() throws {
        let scan = try OcrKit.scan()
        _ = try PdfOcrLayer.add(scan, [OcrPageWords(0, OcrKit.words(), 400, 600)], "en")
        XCTAssertEqual(kindOf(scan), .ownLayer)
        PdfOcrLayer.remove(scan, scan.pages[0])
        XCTAssertEqual(kindOf(scan), .picture)

        let printed = try OcrKit.scan(1, "", "BT /F1 12 Tf 50 500 Td (Hello) Tj ET")
        _ = try PdfOcrLayer.add(printed, [OcrPageWords(0, OcrKit.words(), 400, 600)], "en")
        XCTAssertEqual(kindOf(printed), .ownLayer)
    }

    func test_classifyAllGivesOneKindPerPage() throws {
        let document = try OcrKit.pages("BT /F1 12 Tf 50 500 Td (Hello) Tj ET", "", "0 0 10 10 re f")
        XCTAssertEqual(OcrTriage.classifyAll(document), [.text, .blank, .drawing])
    }

    func test_needsOcr() {
        let cases: [(OcrPageKind, Bool, Bool, Bool)] = [
            (.picture, false, false, true),
            (.drawing, false, false, true),
            (.ownLayer, false, false, false),
            (.ownLayer, true, false, true),
            (.text, true, false, false),
            (.text, false, true, true),
            (.foreignLayer, true, false, false),
            (.foreignLayer, false, true, true),
            (.blank, true, false, false),
        ]
        for (kind, replace, force, expected) in cases {
            XCTAssertEqual(OcrTriage.needsOcr(kind, replace, force), expected, "\(kind) replace \(replace) force \(force)")
        }
    }

    func test_pageThatCannotBeInterpretedDoesNotThrow() throws {
        let document = try OcrKit.scan(1, "", "q q q BT BT ET ET Q Q Q Q Q /Nope Do /F9 12 Tf (x) Tj [ ( ) ")
        let kind = kindOf(document)
        XCTAssertNotNil(OcrPageKind(rawValue: kind.rawValue))
    }
}
