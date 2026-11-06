import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/OcrReviewFixTests.cs: the same cases.

final class OcrReviewFixTests: XCTestCase {
    private let stampedScan = "q 400 0 0 600 0 0 cm /Im1 Do Q BT /F1 60 Tf 20 300 Td (STAMPED) Tj ET"

    private func run(_ session: PdfEditSession, _ words: [OcrWord], _ options: OcrOptions) async throws -> OcrResult {
        try await PdfSearchable.runAsync(session, FakeRecognizer(words), FakeRenderer(session.document), options)
    }

    func test_correctingAWordAfterThePageWasRotatedLeavesTheOtherWordsWhereTheyAre() throws {
        for degrees in [90, 180, 270] {
            let document = try OcrKit.scan()
            let geometry = PageGeometry(document.pages[0])
            _ = try PdfOcrLayer.add(document, [OcrPageWords(0, OcrKit.words(), Int(geometry.width), Int(geometry.height))], "en-US")
            PageOperations.rotate(document, [0], degrees)
            let before = try PdfOcrLayer.words(document, document.pages[0])

            try PdfOcrLayer.correct(document, document.pages[0], 0, "Howdy")

            let after = try PdfOcrLayer.words(document, document.pages[0])
            XCTAssertEqual(OcrKit.texts(after), ["Howdy", "world", "Second", "line"], "\(degrees)")
            for i in 0..<min(before.count, after.count) {
                let (a, b) = (before[i].box, after[i].box)
                XCTAssertTrue(abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5,
                              "\(degrees) word \(i): \(a) became \(b)")
            }
        }
    }

    func test_anOwnLayerIsReplacedOnAPageWithAVisibleStampWhenAskedAndKeptWhenNot() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(1, "", stampedScan))
        let first = try await run(session, OcrKit.words(), OcrOptions(dpi: 72, force: true))
        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(OcrTriage.classify(session.document, session.document.pages[0]), .ownLayer)

        let kept = session.current
        let skipped = try await run(session, [OcrKit.word("Other", 40, 100, 80, 24)], OcrOptions(dpi: 72, force: true))
        XCTAssertEqual(skipped.skipped, 1)
        XCTAssertEqual(session.current, kept)

        let replaced = try await run(session, [OcrKit.word("Fresh", 40, 100, 80, 24)], OcrOptions(dpi: 72, existing: .replace))
        XCTAssertEqual(replaced.added, 1)
        XCTAssertEqual(OcrKit.texts(try PdfOcrLayer.words(session.document, session.document.pages[0])), ["Fresh"])
    }

    func test_blankWordsAreNotCountedAsAddedAndLeavePageWithoutLayer() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes())
        let result = try await run(session, [OcrKit.word("  ", 40, 100, 80, 24)], OcrOptions(dpi: 72))

        XCTAssertEqual(result, OcrResult(0, 1, 0, 0, 0, false))
        XCTAssertFalse(PdfOcrLayer.has(session.document, session.document.pages[0]))
    }
}
