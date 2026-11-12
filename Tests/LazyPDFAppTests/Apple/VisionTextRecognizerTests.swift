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

    func test_aNonsenseTagIsNotAvailable() {
        XCTAssertFalse(VisionTextRecognizer.isAvailable("not a language"))
    }
}
#endif
