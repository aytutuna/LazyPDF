#if canImport(Vision)
@testable import LazyPDFApp
import LazyPDFKit
import XCTest

// Mirrors windows/LazyPDF.App.Tests/WindowsOcrTests.cs. The recognizing tests run only where English is available.

final class VisionTextRecognizerTests: XCTestCase {
    private let recognizer = VisionTextRecognizer()

    func test_theWordsOfADrawnPageAreFoundWithBoxes() async throws {
        try XCTSkipUnless(VisionTextRecognizer.isAvailable("en-US"))
        let session = try PdfEditSession.open(try ApplePdfs.text(line: "Quick brown fox jumps over the lazy dog."))
        let renderer = PdfKitRenderer()
        XCTAssertTrue(renderer.load(session, nil))
        let image = try XCTUnwrap(renderer.render(0, 200))

        let words = try await recognizer.recognizeAsync(image, "en-US")

        XCTAssertTrue(words.contains { $0.text.caseInsensitiveCompare("fox") == .orderedSame })
        for word in words {
            XCTAssertTrue((0...Double(image.width)).contains(word.box.x))
            XCTAssertTrue((0...Double(image.height) + 1).contains(word.box.bottom))
            XCTAssertTrue((0...1).contains(word.confidence))
        }
    }

    func test_aBlankPageHasNoWords() async throws {
        try XCTSkipUnless(VisionTextRecognizer.isAvailable("en-US"))
        let blank = PdfRgbaImage(300, 300, [UInt8](repeating: 255, count: 300 * 300 * 4))

        let words = try await recognizer.recognizeAsync(blank, "en-US")

        XCTAssertTrue(words.isEmpty)
    }

    func test_aLanguageTheSystemDoesNotHaveIsSaidInWords() async {
        let blank = PdfRgbaImage(10, 10, [UInt8](repeating: 0, count: 400))

        do {
            _ = try await recognizer.recognizeAsync(blank, "tlh")
            XCTFail("expected an error")
        } catch let error as InvalidOperationException {
            XCTAssertTrue(error.message.contains("tlh"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_aCancelledRunStops() async throws {
        try XCTSkipUnless(VisionTextRecognizer.isAvailable("en-US"))
        let blank = PdfRgbaImage(10, 10, [UInt8](repeating: 0, count: 400))
        let recognizer = self.recognizer

        let task = Task { () -> [OcrWord] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await recognizer.recognizeAsync(blank, "en-US")
        }

        do {
            _ = try await task.value
            XCTFail("expected the run to stop")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
    }

    func test_englishFollowsAnotherLanguage() throws {
        try XCTSkipUnless(VisionTextRecognizer.isAvailable("en-US"))
        let english = try XCTUnwrap(VisionTextRecognizer.recognitionLanguages(for: "en-US").first)
        XCTAssertEqual(VisionTextRecognizer.recognitionLanguages(for: english), [english])
        try XCTSkipUnless(VisionTextRecognizer.isAvailable("de-DE"))
        let languages = VisionTextRecognizer.recognitionLanguages(for: "de-DE")
        XCTAssertEqual(languages.count, 2)
        XCTAssertTrue(languages[0].hasPrefix("de"))
        XCTAssertTrue(languages[1].hasPrefix("en"))
    }

    func test_aTurnedWordKeepsItsUprightSizeAtTheBaselineStart() {
        // A 100 by 20 word on a 1000 by 500 picture, turned 0.1 rad counter-clockwise about (200, 300) from the top.
        let (w, h) = (1000.0, 500.0), angle = 0.1
        func point(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: (200 + u * cos(angle) - v * sin(angle)) / w, y: (500 - 300 + u * sin(angle) + v * cos(angle)) / h)
        }
        let (bl, br, tl, tr) = (point(0, 0), point(100, 0), point(0, 20), point(100, 20))
        let xs = [bl, br, tl, tr].map(\.x), ys = [bl, br, tl, tr].map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)

        let found = VisionTextRecognizer.lineAngle(bl, br, w, h)
        let box = VisionTextRecognizer.placement(found, bl, br, tl, bounds, w, h)

        XCTAssertEqual(found, angle, accuracy: 1e-9)
        XCTAssertEqual(box.x, 200, accuracy: 1e-6)
        XCTAssertEqual(box.bottom, 300, accuracy: 1e-6)
        XCTAssertEqual(box.width, 100, accuracy: 1e-6)
        XCTAssertEqual(box.height, 20, accuracy: 1e-6)
    }

    func test_aStraightLineKeepsItsBoundsAndNoAngle() {
        // A 40 px word whose corners differ by 0.2 px is noise, not a turn.
        let bounds = CGRect(x: 0.1, y: 0.2, width: 0.04, height: 0.05)
        let (bl, br, tl) = (CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.14, y: 0.2004), CGPoint(x: 0.1, y: 0.25))
        let angle = VisionTextRecognizer.lineAngle(bl, br, 1000, 500)
        let box = VisionTextRecognizer.placement(angle, bl, br, tl, bounds, 1000, 500)

        XCTAssertEqual(angle, 0)
        XCTAssertEqual(box.x, 100, accuracy: 1e-9)
        XCTAssertEqual(box.y, 500 * 0.75, accuracy: 1e-9)
        XCTAssertEqual(box.width, 40, accuracy: 1e-9)
        XCTAssertEqual(box.height, 25, accuracy: 1e-9)
    }

    func test_aNonsenseTagIsNotAvailable() {
        XCTAssertFalse(VisionTextRecognizer.isAvailable("not a language"))
    }
}
#endif
