import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/convert/CreateToolTests.cs: what each source makes and the new tab it opens. The
// Windows ViewModelFixture host is the ViewModelFixture of the Swift tests. TextThatIsNotUtf8IsReadInThePcCodePage names the
// language, since the system's own is not the test's to choose.

@MainActor
private final class CancelledHost: ToolHost {
    private(set) var opened = 0

    func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        let token = CancelToken()
        token.cancel()
        do {
            try await work(token)
        } catch is CancellationError {
        }
    }

    func setBusyText(_ text: String) {}
    func showProblem(_ problem: Problem) { XCTFail(problem.title) }
    func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) { XCTFail(title) }
    func setStatus(_ sentence: String) {}
    func open(_ url: URL, access: FileAccess?) async {}

    func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {
        opened += 1
    }

    func tryReload(_ tab: DocumentTab) async -> Bool { true }
}

final class CreateToolTests: XCTestCase {
    private let a4 = PdfPageSetup()

    private func png() throws -> [UInt8] {
        try PngWriter.encode(PdfRgbaImage(8, 8, [UInt8](repeating: 200, count: 8 * 8 * 4)))
    }

    private func make(_ request: CreateRequest, codec: ImageCodec = FakeCodec(), fonts: FontSource = FakeFonts(),
                      token: CancelToken = CancelToken()) throws -> MadePdf {
        try PdfMaker.make(request, codec, fonts, token)
    }

    func test_blankPagesAreEmptyAndAsBigAsAsked() throws {
        let setup = PdfPageSetup(paper: .letter, orientation: .landscape)

        let made = try make(CreateRequest(.blank, setup, "Blank.pdf", pages: 3))

        let document = try PdfDocument.open(made.bytes)
        XCTAssertEqual(made.pages, 3)
        XCTAssertEqual(document.pages.count, 3)
        XCTAssertEqual(document.pages[0].mediaBox.width, 792)
        XCTAssertEqual(document.pages[0].mediaBox.height, 612)
        let text = try PlainTextWriter.make(ExportLayout.analyze(document))
        XCTAssertEqual(text.replacingOccurrences(of: "\u{0C}", with: "").trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func test_picturesBecomePagesInTheOrderGiven() throws {
        let dir = TempDir(self)
        let first = dir.file("a.png", try png()), second = dir.file("b.png", try png())

        let made = try make(CreateRequest(.pictures, a4, "Pictures.pdf", files: [second, first]))

        XCTAssertEqual(made.pages, 2)
        XCTAssertEqual(made.unreadable, 0)
        XCTAssertEqual(try PdfDocument.open(made.bytes).pages.count, 2)
    }

    func test_aPictureThatCannotBeReadIsCountedAndTheRestStay() throws {
        let dir = TempDir(self)
        let good = dir.file("a.png", try png()), bad = dir.file("b.png", [])

        let made = try make(CreateRequest(.pictures, a4, "Pictures.pdf", files: [good, bad]))

        XCTAssertEqual(made.pages, 1)
        XCTAssertEqual(made.unreadable, 1)
    }

    func test_aPictureTooBigToDecodeIsCountedAndTheRestStay() throws {
        final class BigCodec: ImageCodec {
            func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
            func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? {
                [PdfRgbaImage(4, 4, [UInt8](repeating: 128, count: 64)), PdfRgbaImage(60000, 60000, [])]
            }
            func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
        }
        let dir = TempDir(self)
        let file = dir.file("a.png", try png())

        let made = try make(CreateRequest(.pictures, a4, "Pictures.pdf", files: [file]), codec: BigCodec())

        XCTAssertEqual(made.pages, 1)
        XCTAssertEqual(made.tooLarge, 1)
        XCTAssertEqual(made.unreadable, 0)
    }

    @MainActor
    func test_picturesLeftOutForSizeAreSaid() async throws {
        final class BigCodec: ImageCodec {
            func decode(_ data: [UInt8], _ codec: String) -> PdfRgbaImage? { nil }
            func decodeFile(_ file: [UInt8]) -> [PdfRgbaImage]? {
                [PdfRgbaImage(4, 4, [UInt8](repeating: 128, count: 64)), PdfRgbaImage(60000, 60000, [])]
            }
            func encodeJpeg(_ image: PdfRgbaImage, _ quality: Int) -> [UInt8] { [] }
        }
        let f = ViewModelFixture(self)
        let file = TempDir(self).file("a.png", try png())

        try await CreateJob.run(f.vm, BigCodec(), FakeFonts(), CreateRequest(.pictures, a4, "Pictures.pdf", files: [file]))

        XCTAssertEqual(f.vm.message?.title, "Some left out")
        XCTAssertEqual(f.vm.message?.text, "1 picture was too large and was left out.")
    }

    #if canImport(ImageIO)
    func test_thePictureOnTheClipboardIsOnePage() throws {
        let setup = PdfPageSetup(paper: .picture, margin: 10)

        let made = try make(CreateRequest(.pictures, setup, "Clipboard.pdf", picture: try png()), codec: ImageIOCodec())

        let page = try PdfDocument.open(made.bytes).pages[0]
        XCTAssertEqual(made.pages, 1)
        XCTAssertEqual(page.mediaBox.width, 26)
        XCTAssertEqual(page.mediaBox.height, 26)
    }
    #endif

    #if canImport(CoreText)
    func test_turkishTextKeepsItsLetters() throws {
        let made = try make(CreateRequest(.text, a4, "Text.pdf", text: "Çalışma notları: ğ ş ı İ ö ü", fontSize: 14), fonts: CoreTextFontSource())

        XCTAssertEqual(made.unreadable, 0)
        let text = try PlainTextWriter.make(ExportLayout.analyze(try PdfDocument.open(made.bytes)))
        XCTAssertTrue(text.contains("Çalışma notları: ğ ş ı İ ö ü"))
    }
    #endif

    func test_aLongTextRunsOverToMorePages() throws {
        let text = (0..<200).map { "Line \($0)" }.joined(separator: "\n")

        let made = try make(CreateRequest(.text, a4, "Text.pdf", text: text))

        XCTAssertGreaterThan(made.pages, 2)
    }

    @MainActor
    func test_theResultOpensInANewTabThatNeedsAName() async throws {
        let f = ViewModelFixture(self)

        try await CreateJob.run(f.vm, FakeCodec(), FakeFonts(), CreateRequest(.text, a4, "Text.pdf", text: "Hello"))

        let tab = try XCTUnwrap(f.vm.activeDocument)
        XCTAssertEqual(tab.title, "Text.pdf")
        XCTAssertTrue(AppViewModel.needsName(tab))
        XCTAssertTrue(tab.isDirty)
        XCTAssertNil(f.vm.message)
    }

    @MainActor
    func test_aCreatedDocumentLeavesTheOpenOneAlone() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.pdf())
        let first = try XCTUnwrap(f.vm.activeDocument)
        let revision = first.revision

        try await CreateJob.run(f.vm, FakeCodec(), FakeFonts(), CreateRequest(.blank, a4, "Blank.pdf", pages: 2))

        XCTAssertEqual(f.vm.documents.count, 2)
        XCTAssertEqual(first.revision, revision)
        XCTAssertEqual(f.vm.activeDocument?.pageCount, 2)
    }

    @MainActor
    func test_textNoFontCanDrawIsAProblem() async throws {
        let f = ViewModelFixture(self)

        try await CreateJob.run(f.vm, FakeCodec(), FakeFonts(), CreateRequest(.text, a4, "Text.pdf", text: "ğ ş ı"))

        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(f.vm.message?.title, "No font for this text")
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    @MainActor
    func test_picturesNoneOfWhichCanBeReadAreAProblem() async throws {
        let f = ViewModelFixture(self)
        let empty = f.dir.file("a.png", [])

        try await CreateJob.run(f.vm, FakeCodec(), FakeFonts(), CreateRequest(.pictures, a4, "Pictures.pdf", files: [empty]))

        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(f.vm.message?.title, "No picture to use")
        XCTAssertTrue(f.vm.documents.isEmpty)
    }

    @MainActor
    func test_aMarginTooWideForThePageIsAProblem() async throws {
        let f = ViewModelFixture(self)

        try await CreateJob.run(f.vm, FakeCodec(), FakeFonts(), CreateRequest(.text, PdfPageSetup(margin: 400), "Text.pdf", text: "Hello"))

        XCTAssertEqual(f.vm.message?.title, "Margin is too wide")
    }

    @MainActor
    func test_aPictureLeftOutIsReportedAfterTheTabOpens() async throws {
        let f = ViewModelFixture(self)
        let good = f.dir.file("a.png", try png()), bad = f.dir.file("b.png", [])

        try await CreateJob.run(f.vm, FakeCodec(), FakeFonts(), CreateRequest(.pictures, a4, "Pictures.pdf", files: [good, bad]))

        XCTAssertEqual(f.vm.documents.count, 1)
        XCTAssertEqual(f.vm.message?.isError, false)
        XCTAssertEqual(f.vm.message?.text, "1 picture could not be read.")
    }

    @MainActor
    func test_aCancelledCreateOpensNothing() async throws {
        let host = CancelledHost()

        try await CreateJob.run(host, FakeCodec(), FakeFonts(), CreateRequest(.blank, a4, "Blank.pdf", pages: 3))

        XCTAssertEqual(host.opened, 0)
    }

    func test_aCancelStopsTheReadingOfPictures() throws {
        let file = TempDir(self).file("a.png", try png())
        let token = CancelToken()
        token.cancel()

        XCTAssertThrowsError(try make(CreateRequest(.pictures, a4, "Pictures.pdf", files: [file]), token: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func test_textInUtf8OrWithAByteOrderMarkReadsAsWritten() {
        let text = "Çalışma notları: ğ ş ı İ ö ü"
        let utf8 = Array(text.utf8)

        XCTAssertEqual(TextFiles.decode(utf8), text)
        XCTAssertEqual(TextFiles.decode([0xEF, 0xBB, 0xBF] + utf8), text)
        XCTAssertEqual(TextFiles.decode([0xFF, 0xFE] + text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), text)
        XCTAssertEqual(TextFiles.decode([0xFE, 0xFF] + text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }), text)
    }

    func test_textThatIsNotUtf8IsReadInThePcCodePage() {
        // 0xFE never occurs in UTF-8; in Windows-1254 it is ş.
        let bytes: [UInt8] = [0xFE, 0x20, 0xFD]

        XCTAssertEqual(TextFiles.decode(bytes, language: "tr-TR"), "ş ı")
        XCTAssertEqual(TextFiles.decode(bytes, language: "en-US"), "þ ý")
    }
}
