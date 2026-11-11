import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/PdfFromTextTests.cs: the same cases. The C# font source reads Arial; the
// synthetic font here has A, B, space, ğ, İ and À only (ı has the glyph of ğ and reads back as ğ), so those letters stand for
// the Turkish prose and CharactersTheFontLacksAreReported uses "AB 中". The PdfPig assertion of TurkishTextIsEmbeddedAndReadsBack has no twin; the rest stays.

final class PdfFromTextTests: XCTestCase {
    private func pageText(_ file: [UInt8], _ page: Int) throws -> String {
        let document = try PdfDocument.open(file)
        return TextPage.create(document, document.pages[page]).text
    }

    func test_shortAsciiTextNeedsNoFontSource() throws {
        let made = try PdfFromText.create("Hello\nWorld")
        XCTAssertEqual(made.pages, 1)
        XCTAssertTrue(made.missing.isEmpty)
        XCTAssertEqual(try pageText(made.bytes, 0), "Hello\nWorld")
    }

    func test_longLinesWrapInsideTheMargin() throws {
        let text = (0..<150).map { "word\($0)" }.joined(separator: " ")
        let made = try PdfFromText.create(text, setup: PdfPageSetup(margin: 72))
        let document = try PdfDocument.open(made.bytes)
        let recorder = Recorder()
        ContentInterpreter(document).run(document.pages[0], recorder)
        for g in recorder.glyphs {
            XCTAssertTrue(g.bounds.left >= 71.9 && g.bounds.left <= 595.276 - 72 + 0.1, "\(g.bounds.left)")
            XCTAssertTrue(g.bounds.right >= 71.9 && g.bounds.right <= 595.276 - 72 + 0.1, "\(g.bounds.right)")
        }
        let lines = try pageText(made.bytes, 0).components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 3)
        XCTAssertEqual(lines.joined(separator: " "), text)
    }

    func test_manyLinesFlowOntoMorePages() throws {
        let text = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let made = try PdfFromText.create(text)
        // 841.89 - 72 points of room at 11 pt Arial-class metrics.
        XCTAssertTrue(made.pages >= 4 && made.pages <= 6, "\(made.pages) pages")
        let all = try (0..<made.pages).map { try pageText(made.bytes, $0) }.joined(separator: "\n")
        XCTAssertEqual(all, text)
    }

    func test_aFormFeedStartsAPageAndATrailingOneAddsNone() throws {
        XCTAssertEqual(try PdfFromText.create("one\u{0C}two\u{0C}three").pages, 3)
        let made = try PdfFromText.create("one\u{0C}two\u{0C}")
        XCTAssertEqual(made.pages, 2)
        XCTAssertEqual(try pageText(made.bytes, 1), "two")
    }

    func test_tabsAreFourSpacesAndOtherControlCharactersGoAway() throws {
        let made = try PdfFromText.create("a\tb\u{01}c\r\nd")
        XCTAssertEqual(try pageText(made.bytes, 0), "a    bc\nd")
    }

    func test_anEmptyTextIsOneBlankPage() throws {
        let made = try PdfFromText.create("")
        XCTAssertEqual(made.pages, 1)
        XCTAssertEqual(try pageText(made.bytes, 0), "")
    }

    func test_aWordWiderThanTheLineBreaksWithinIt() throws {
        let word = String(repeating: "x", count: 400)
        let made = try PdfFromText.create(word)
        XCTAssertEqual(try pageText(made.bytes, 0).replacingOccurrences(of: "\n", with: ""), word)
    }

    func test_letterAndLandscapeSetThePage() throws {
        let document = try PdfDocument.open(PdfFromText.create("x", setup: PdfPageSetup(paper: .letter, orientation: .landscape)).bytes)
        XCTAssertEqual([document.pages[0].mediaBox.width, document.pages[0].mediaBox.height], [792, 612])
    }

    func test_turkishTextIsEmbeddedAndReadsBack() throws {
        let turkish = "AB ğİ BA À\nAB ğ İ"
        let made = try PdfFromText.create(turkish, fonts: ExportArialSource())
        XCTAssertTrue(made.missing.isEmpty)
        XCTAssertEqual(try pageText(made.bytes, 0), turkish)
        let document = try PdfDocument.open(made.bytes)
        let fonts = try XCTUnwrap(document.resolve(document.pages[0].resources?["Font"]) as? PdfDictionary)
        let dictionary = try XCTUnwrap(document.resolve(fonts["F1"]) as? PdfDictionary)
        XCTAssertTrue(PdfFont.get(document, dictionary).isEmbedded)
    }

    func test_turkishWithoutAFontFileIsRefused() {
        XCTAssertThrowsError(try PdfFromText.create("ğüşıİ")) { error in
            XCTAssertTrue(error is InvalidOperationException)
            XCTAssertEqual("\(error)", ExportText.noFont)
        }
    }

    func test_charactersTheFontLacksAreReported() throws {
        let made = try PdfFromText.create("AB 中", fonts: ExportArialSource())
        XCTAssertEqual(made.missing, [0x4E2D])
    }

    func test_aRoomLessPageIsRefused() {
        XCTAssertThrowsError(try PdfFromText.create("x", setup: PdfPageSetup(margin: 400))) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try PdfFromText.create("x", setup: PdfPageSetup(margin: -5))) { XCTAssertTrue($0 is ArgumentException) }
        XCTAssertThrowsError(try PdfFromText.create("x", size: 0)) { XCTAssertTrue($0 is ArgumentException) }
    }

    func test_aCancelledTokenStopsTheMakingOfThePdf() async throws {
        let task = Task { () -> TextPdf in
            while !Task.isCancelled { await Task.yield() }
            return try PdfFromText.create("Hello\u{0C}World")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
    }

    func test_aCancelDuringTheFontLookupStopsBeforeThePages() async throws {
        let fonts = CancellingFonts(try ExportArialSource())
        let task = Task { try PdfFromText.create("AB ğİ\u{0C}İ ğ", fonts: fonts) }
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(fonts.asked, 1)
    }

    private final class CancellingFonts: FontSource {
        private let inner: FontSource
        private(set) var asked = 0

        init(_ inner: FontSource) { self.inner = inner }

        func find(_ family: String, _ style: FontStyles) -> FontFile? {
            asked += 1
            withUnsafeCurrentTask { $0?.cancel() }
            return inner.find(family, style)
        }
    }}
