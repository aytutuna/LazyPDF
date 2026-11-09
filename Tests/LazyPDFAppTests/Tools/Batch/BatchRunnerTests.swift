import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/measure/BatchRunnerTests.cs: the steps of a batch against real engine calls on small
// files. The two PDF/A tests need the system's fonts and run where CoreText is. The runner is given the folder the results go
// to, since the Mac and iOS apps get it from the person and not from the set.

struct FakeRecognizer: TextRecognizer {
    var words: [OcrWord] = [OcrWord("Invoice", OcrBox(0, 0, 2, 1))]
    var onRead: (@Sendable () -> Void)?

    func recognizeAsync(_ image: PdfRgbaImage, _ language: String) async throws -> [OcrWord] {
        onRead?()
        return words
    }
}

final class RecordingWriter: FileWriter {
    private(set) var targets: [URL] = []

    func write(to url: URL, _ write: (URL) throws -> Void) throws {
        targets.append(url)
        try write(url)
    }
}

final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        found.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return found
    }
}

func batchFonts() -> FontSource {
    #if canImport(CoreText)
    return CoreTextFontSource()
    #else
    return FakeFonts()
    #endif
}

final class BatchRunnerTests: XCTestCase {
    private let now = DateTimeOffset(2026, 3, 9, 12, 0, 0)

    private func runner(_ recognizer: TextRecognizer = FakeRecognizer()) -> BatchRunner {
        BatchRunner(codec: FakeCodec(), fonts: batchFonts(), recognizer: recognizer, renderers: { FakeRenderer() })
    }

    private func step(_ kind: BatchStepKind, _ text: String = "") -> BatchStep {
        var step = BatchStep(kind)
        step.text = text
        return step
    }

    private func run(_ runner: BatchRunner, _ file: URL, _ set: inout BatchSet, into folder: URL, number: Int = 1,
                     token: CancelToken = CancelToken()) async throws -> BatchResult {
        try await runner.run(file, &set, into: folder, number: number, now: now, token: token)
    }

    private func text(_ url: URL, _ page: Int) throws -> String {
        let document = try PdfDocument.open([UInt8](try Data(contentsOf: url)))
        return TextPage.create(document, document.pages[page]).text
    }

    func test_aFileGoesThroughTheStepsAndIsWrittenUnderANewName() async throws {
        let dir = TempDir(self)
        let original = Pdfs.text(2)
        let file = dir.file("report.pdf", original)
        var set = BatchSet(steps: [step(.watermark, "DRAFT"), step(.compress), step(.clean)], nameTemplate: "{name}-{n}")

        let result = try await run(runner(), file, &set, into: dir.sub("out"), number: 7)

        XCTAssertTrue(result.ok, result.detail)
        XCTAssertEqual(result.output?.path, dir.sub("out").appendingPathComponent("report-7.pdf").path)
        let made = try PdfDocument.open([UInt8](try Data(contentsOf: try XCTUnwrap(result.output))))
        XCTAssertEqual(made.pages.count, 2)
        XCTAssertEqual(PdfStamper(made).list().map(\.label), ["DRAFT"])
        XCTAssertEqual([UInt8](try Data(contentsOf: file)), original)
    }

    func test_aNameThatIsTakenGetsANumberAndNothingIsOverwritten() async throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        var set = BatchSet(steps: [step(.clean)])

        let first = try await run(runner(), file, &set, into: dir.sub("out"))
        let second = try await run(runner(), file, &set, into: dir.sub("out"))

        XCTAssertEqual(first.output?.lastPathComponent, "a.pdf")
        XCTAssertEqual(second.output?.lastPathComponent, "a (2).pdf")
    }

    func test_batesNumbersRunOnFromOneFileToTheNext() async throws {
        let dir = TempDir(self)
        let one = dir.file("one.pdf", Pdfs.text(3)), two = dir.file("two.pdf", Pdfs.text(2))
        var bates = step(.bates, "AB-")
        bates.digits = 4
        bates.start = 10
        var set = BatchSet(steps: [bates])
        let runner = runner()

        let a = try await run(runner, one, &set, into: dir.sub("out"))
        XCTAssertEqual(set.steps[0].start, 13)
        let b = try await run(runner, two, &set, into: dir.sub("out"))
        XCTAssertEqual(set.steps[0].start, 15)

        XCTAssertTrue(try text(try XCTUnwrap(a.output), 0).contains("AB-0010"))
        XCTAssertTrue(try text(try XCTUnwrap(a.output), 2).contains("AB-0012"))
        XCTAssertTrue(try text(try XCTUnwrap(b.output), 0).contains("AB-0013"))

        set.steps[0].start = 10
        let again = try await run(runner, two, &set, into: dir.sub("out"))
        XCTAssertTrue(try text(try XCTUnwrap(again.output), 0).contains("AB-0010"))
    }

    func test_pagesThatArePicturesGetATextLayer() async throws {
        let dir = TempDir(self)
        let file = dir.file("scan.pdf", try PdfFromPictures.create([[1, 2, 3]], FakeCodec()).bytes)
        var set = BatchSet(steps: [step(.ocr, "en-US")])

        let result = try await run(runner(), file, &set, into: dir.sub("out"))

        XCTAssertTrue(result.ok, result.detail)
        let made = try PdfDocument.open([UInt8](try Data(contentsOf: try XCTUnwrap(result.output))))
        XCTAssertTrue(PdfOcrLayer.has(made, made.pages[0]))
    }

    #if canImport(CoreText)
    func test_aPdfAStepWritesAFileThatPassesTheFileRules() async throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        var pdfA = BatchStep(.pdfA)
        pdfA.level = .a2b
        var set = BatchSet(steps: [pdfA])

        let result = try await run(runner(), file, &set, into: dir.sub("out"))

        XCTAssertTrue(result.ok, result.detail)
        let made = try PdfDocument.open([UInt8](try Data(contentsOf: try XCTUnwrap(result.output))))
        XCTAssertFalse(PdfAValidator.validate(made, .a2b).issues.contains { $0.where == "Catalog" })
    }

    func test_aRuleLeftAfterPdfAIsCountedWhenAStepComesAfterIt() async throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        var pdfA = BatchStep(.pdfA)
        pdfA.level = .a2b
        var set = BatchSet(steps: [pdfA, step(.clean)])

        let result = try await run(runner(), file, &set, into: dir.sub("out"))

        XCTAssertTrue(result.ok, result.detail)
        XCTAssertTrue(result.detail.contains("PDF/A rule"))
    }
    #endif

    func test_aFileThatNeedsAPasswordIsReportedAndTheRunGoesOn() async throws {
        let dir = TempDir(self)
        let locked = dir.file("locked.pdf", Pdfs.fixture("locked.pdf"))
        var set = BatchSet(steps: [step(.clean)])

        let failed = try await run(runner(), locked, &set, into: dir.sub("out"))
        let fine = try await run(runner(), dir.file("b.pdf", Pdfs.text()), &set, into: dir.sub("out"))

        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.title, "File is locked")
        XCTAssertNil(failed.output)
        XCTAssertTrue(fine.ok)
    }

    func test_aWatermarkWithNoTextFailsWithWhatToDo() async throws {
        let dir = TempDir(self)
        var set = BatchSet(steps: [step(.watermark, "  ")])

        let result = try await run(runner(), dir.file("a.pdf", Pdfs.text()), &set, into: dir.sub("out"))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.title, "Watermark has no text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.sub("out").path))
    }

    func test_aMissingFileIsAResultNotACrash() async throws {
        let dir = TempDir(self)
        var set = BatchSet(steps: [step(.clean)])

        let result = try await run(runner(), dir.sub("gone.pdf"), &set, into: dir.sub("out"))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.title, "File not found")
    }

    func test_theFileIsReadAndTheResultWrittenThroughTheShellsReaderAndWriter() async throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        let writer = RecordingWriter()
        let read = ReadLog()
        let made = BatchRunner(codec: FakeCodec(), fonts: batchFonts(), recognizer: FakeRecognizer(), renderers: { FakeRenderer() },
                               writer: writer, reader: { read.add($0); return try Data(contentsOf: $0) })
        var set = BatchSet(steps: [step(.clean)])

        let result = try await run(made, file, &set, into: dir.sub("out"))

        XCTAssertTrue(result.ok, result.detail)
        XCTAssertEqual(read.urls, [file])
        XCTAssertEqual(writer.targets.map(\.lastPathComponent), ["a.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.sub("out/a.pdf").path))
    }

    func test_aCancelStopsTheRun() async throws {
        let dir = TempDir(self)
        let token = CancelToken()
        token.cancel()
        var set = BatchSet(steps: [step(.clean)])
        let file = dir.file("a.pdf", Pdfs.text())

        do {
            _ = try await run(runner(), file, &set, into: dir.sub("out"), token: token)
            XCTFail("the run was not stopped")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_aFileThatLimitsWhatMayBeDoneIsRefusedAndNothingIsWritten() async throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", try Pdfs.restricted(.print))
        var set = BatchSet(steps: [step(.compress)])

        let result = try await run(runner(), file, &set, into: dir.sub("out"))

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.title, "File is protected")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.sub("out").path))
    }

    func test_aFileThatOpensFreelyKeepsItsEncryptionThroughCompressAndClean() async throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", try Pdfs.restricted(.all))
        var set = BatchSet(steps: [step(.compress), step(.clean)])

        let result = try await run(runner(), file, &set, into: dir.sub("out"))

        XCTAssertTrue(result.ok, result.detail)
        let made = try PdfDocument.open([UInt8](try Data(contentsOf: try XCTUnwrap(result.output))))
        XCTAssertNotNil(made.security)
    }

    func test_aCancelDuringAStepStopsTheRunBeforeAnythingIsWritten() async throws {
        let dir = TempDir(self)
        let token = CancelToken()
        let cancelling = FakeRecognizer(onRead: { token.cancel() })
        let file = dir.file("scan.pdf", try PdfFromPictures.create([[1, 2, 3]], FakeCodec()).bytes)
        var set = BatchSet(steps: [step(.ocr, "en-US"), step(.clean), step(.compress)])

        do {
            _ = try await run(runner(cancelling), file, &set, into: dir.sub("out"), token: token)
            XCTFail("the run was not stopped")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.sub("out").path))
    }

    func test_aPageWithNoTextIsSaidInTheLogNotJustDone() async throws {
        let dir = TempDir(self)
        let file = dir.file("scan.pdf", try PdfFromPictures.create([[1, 2, 3]], FakeCodec()).bytes)
        var set = BatchSet(steps: [step(.ocr, "en-US")])

        let result = try await run(runner(FakeRecognizer(words: [])), file, &set, into: dir.sub("out"))

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.title, "Done, with notes")
        XCTAssertTrue(result.detail.contains("No text found on 1 page"))
    }

    func test_commentsAndFormsStayOnlyWhereTheStepKeepsThem() async throws {
        let dir = TempDir(self)
        let session = try PdfEditSession.open(Pdfs.text())
        _ = try PdfAnnotationWriter(session.document).addNote(session.document.pages[0], PdfRect(50, 50, 70, 70),
                                                          AnnotationInfo(author: "Sam", contents: "Check this"))
        try session.commit("Note")
        let file = dir.file("a.pdf", session.current)
        var removing = BatchSet(steps: [step(.clean)])
        var keepStep = BatchStep(.clean)
        keepStep.keepComments = true
        var keeping = BatchSet(steps: [keepStep])

        let removed = try await run(runner(), file, &removing, into: dir.sub("one"))
        let kept = try await run(runner(), file, &keeping, into: dir.sub("two"))

        func notes(_ url: URL?) throws -> Int {
            let made = try PdfDocument.open([UInt8](try Data(contentsOf: try XCTUnwrap(url))))
            return PdfAnnotations.read(made, made.pages[0]).filter { $0.type == .text }.count
        }
        XCTAssertEqual(try notes(removed.output), 0)
        XCTAssertEqual(try notes(kept.output), 1)
    }

    func test_aResultsFolderThatCannotBeMadeIsAWriteProblemNotAReadProblem() async throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        let taken = dir.file("taken", [1])
        var set = BatchSet(steps: [step(.clean)])

        let result = try await run(runner(), file, &set, into: taken)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.title, "Not saved")
    }
}
