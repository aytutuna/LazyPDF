import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/PdfSearchableTests.cs: the same cases. IProgress is a closure and the
// CancellationToken is the task's own: the cancel tests cancel the task the run is in. The PdfPig reading of the encrypted
// file (EncryptedFileKeepsItsEncryptionAndTakesTheLayer) has no twin.

final class PdfSearchableTests: XCTestCase {
    private final class Reports {
        var items: [OcrProgress] = []

        func report(_ value: OcrProgress) { items.append(value) }
    }

    private struct EngineFailure: Error {}

    private func run(_ session: PdfEditSession, _ recognizer: FakeRecognizer, _ options: OcrOptions = OcrOptions(dpi: 72),
                     _ reports: Reports? = nil, _ renderer: FakeRenderer? = nil) async throws -> OcrResult {
        let renderer = renderer ?? FakeRenderer(session.document)
        return try await PdfSearchable.runAsync(session, recognizer, renderer, options, reports.map { r in { (progress: OcrProgress) in r.report(progress) } })
    }

    func test_scannedPagesGetALayerAsOneUndoableStep() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(3))
        let recognizer = FakeRecognizer(OcrKit.words(dpi: 144))
        let renderer = FakeRenderer(session.document)
        let reports = Reports()
        let result = try await run(session, recognizer, OcrOptions(language: "tr-TR", dpi: 144), reports, renderer)

        XCTAssertEqual(result, OcrResult(3, 0, 0, 0, 12, true))
        XCTAssertEqual(renderer.calls.map { $0.page }, [0, 1, 2])
        XCTAssertTrue(renderer.calls.allSatisfy { $0.dpi == 144 })
        XCTAssertTrue(recognizer.calls.allSatisfy { $0.width == 800 && $0.height == 1200 && $0.language == "tr-TR" })
        XCTAssertEqual(reports.items.map { [$0.pageIndex, $0.done, $0.total] }, [[0, 1, 3], [1, 2, 3], [2, 3, 3]])
        XCTAssertTrue(reports.items.allSatisfy { $0.outcome == .added })
        XCTAssertEqual(session.undoLabel, OcrStatusText.label)

        for i in 0..<3 { OcrKit.assertAtBoxes(session.document, i) }
        XCTAssertTrue(try session.undo())
        XCTAssertFalse(PdfOcrLayer.has(session.document, session.document.pages[0]))
    }

    func test_readingAloneLeavesTheDocumentAndGivesTheWordsToWrite() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(2))
        let read = try await PdfSearchable.readAsync(session.document, FakeRecognizer(OcrKit.words()), FakeRenderer(session.document), OcrOptions(dpi: 72))

        XCTAssertEqual(read.result, OcrResult(2, 0, 0, 0, 0, false))
        XCTAssertEqual(read.pages.map { $0.pageIndex }, [0, 1])
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(PdfOcrLayer.has(session.document, session.document.pages[0]))
    }

    func test_wordsAreAtTheirBoxesWhateverTheResolution() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(1, "/Rotate 90"))
        _ = try await run(session, FakeRecognizer(OcrKit.words(dpi: 200)), OcrOptions(dpi: 200))
        OcrKit.assertAtBoxes(session.document)
    }

    func test_secondRunSkipsReplaceKeepsOneLayer() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(2))
        _ = try await run(session, FakeRecognizer(OcrKit.words()))
        let first = session.current

        let again = FakeRecognizer(OcrKit.words())
        let skipped = try await run(session, again)
        XCTAssertEqual(skipped, OcrResult(0, 0, 2, 0, 0, false))
        XCTAssertTrue(again.calls.isEmpty)
        XCTAssertEqual(session.current, first)

        let replaced = try await run(session, FakeRecognizer([OcrKit.word("Fresh", 40, 100, 80, 24)]), OcrOptions(dpi: 72, existing: .replace))
        XCTAssertEqual(replaced, OcrResult(2, 0, 0, 0, 2, true))
        for i in [0, 1] {
            XCTAssertEqual(OcrKit.layerStreams(session.document, i), 1)
            XCTAssertEqual(TextPage.create(session.document, session.document.pages[i]).words.map { $0.text }, ["Fresh"])
        }

        _ = try await run(session, FakeRecognizer(OcrKit.words()), OcrOptions(dpi: 72, existing: .replace))
        _ = try await run(session, FakeRecognizer(OcrKit.words()), OcrOptions(dpi: 72, existing: .replace))
        XCTAssertEqual(OcrKit.layerStreams(session.document), 1)
        OcrKit.assertAtBoxes(session.document)
        let reopened = try PdfDocument.open(session.current)
        XCTAssertEqual(OcrKit.layerStreams(reopened), 1)
        XCTAssertEqual(TextPage.create(reopened, reopened.pages[0]).words.count, 4)
    }

    func test_replaceWithNoWordsRemovesTheOldLayer() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes())
        _ = try await run(session, FakeRecognizer(OcrKit.words()))
        let result = try await run(session, FakeRecognizer([]), OcrOptions(dpi: 72, existing: .replace))
        XCTAssertEqual(result, OcrResult(0, 1, 0, 0, 0, true))
        XCTAssertFalse(PdfOcrLayer.has(session.document, session.document.pages[0]))
    }

    func test_pagesWithTextAreLeftAloneUnlessForced() async throws {
        let pdf = try OcrKit.pages("BT /F1 12 Tf 50 500 Td (Printed) Tj ET", "")
        let session = try PdfEditSession.open(try pdf.saveRewrite())
        let recognizer = FakeRecognizer(OcrKit.words())
        let plain = try await run(session, recognizer)
        // The empty page has nothing drawn, so it is skipped too.
        XCTAssertEqual(plain, OcrResult(0, 0, 2, 0, 0, false))
        XCTAssertTrue(recognizer.calls.isEmpty)

        let forced = try await run(session, recognizer, OcrOptions(dpi: 72, force: true))
        XCTAssertEqual(forced.added, 2)
        let words = TextPage.create(session.document, session.document.pages[0]).words.map { $0.text }
        XCTAssertTrue(words.contains("Printed"))
        XCTAssertTrue(words.contains("Hello"))
    }

    func test_pageSelectionIsBoundedAndOrdered() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(4))
        let reports = Reports()
        let result = try await run(session, FakeRecognizer(OcrKit.words()), OcrOptions(dpi: 72, pages: [3, 1, 3, 99, -1]), reports)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(reports.items.map { $0.pageIndex }, [1, 3])
        XCTAssertEqual(session.document.pages.map { PdfOcrLayer.has(session.document, $0) }, [false, true, false, true])
    }

    func test_pageTheRendererCannotDrawIsCountedAndTheRestIsDone() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(3))
        let reports = Reports()
        let result = try await run(session, FakeRecognizer(OcrKit.words()), OcrOptions(dpi: 72), reports, FakeRenderer(session.document, 1))
        XCTAssertEqual(result, OcrResult(2, 0, 0, 1, 8, true))
        XCTAssertEqual(reports.items.map { $0.outcome }, [.added, .notRendered, .added])
    }

    func test_nothingToDoCommitsNothing() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(1, "", ""))
        let result = try await run(session, FakeRecognizer(OcrKit.words()))
        XCTAssertFalse(result.committed)
        XCTAssertFalse(session.canUndo)
    }

    func test_cancelLeavesTheDocumentAsItWas() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(4))
        let before = session.current
        let recognizer = FakeRecognizer(OcrKit.words())
        recognizer.before = { call in
            if call == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let task = Task { try await self.run(session, recognizer) }
        do {
            _ = try await task.value
            XCTFail("the run was not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(recognizer.calls.count, 3)
        XCTAssertEqual(session.current, before)
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.document.hasChanges)
    }

    func test_cancelBeforeStartDoesNotCallTheRecognizer() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(2))
        let recognizer = FakeRecognizer(OcrKit.words())
        let task = Task { () -> OcrResult in
            while !Task.isCancelled { await Task.yield() }
            return try await self.run(session, recognizer)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("the run was not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(recognizer.calls.isEmpty)
    }

    func test_cancelKeepsTheFinishedPagesWhenAsked() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(3))
        let recognizer = FakeRecognizer(OcrKit.words())
        recognizer.before = { call in
            if call == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            try Task.checkCancellation()
        }
        let task = Task { try await PdfSearchable.readAsync(session.document, recognizer, FakeRenderer(session.document), OcrOptions(dpi: 72), keepPartial: true) }
        let read = try await task.value
        XCTAssertTrue(read.stopped)
        XCTAssertEqual(read.pages.map { $0.pageIndex }, [0, 1])
        XCTAssertEqual(read.result, OcrResult(2, 0, 0, 0, 0, false))
        XCTAssertFalse(session.document.hasChanges)

        let again = FakeRecognizer(OcrKit.words())
        again.before = recognizer.before
        let plain = Task { try await PdfSearchable.readAsync(session.document, again, FakeRenderer(session.document), OcrOptions(dpi: 72)) }
        do {
            _ = try await plain.value
            XCTFail("the read was not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func test_cancelBeforeStartKeepsNothingWhenAsked() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(2))
        let recognizer = FakeRecognizer(OcrKit.words())
        let task = Task { () -> OcrRead in
            while !Task.isCancelled { await Task.yield() }
            return try await PdfSearchable.readAsync(session.document, recognizer, FakeRenderer(session.document), OcrOptions(dpi: 72), keepPartial: true)
        }
        task.cancel()
        let read = try await task.value
        XCTAssertTrue(read.stopped)
        XCTAssertTrue(read.pages.isEmpty)
        XCTAssertEqual(read.result, OcrResult(0, 0, 0, 0, 0, false))
        XCTAssertTrue(recognizer.calls.isEmpty)
    }

    func test_recognizerFailureLeavesTheDocumentAsItWas() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(3))
        let recognizer = FakeRecognizer(OcrKit.words())
        recognizer.before = { call in
            if call == 1 { throw EngineFailure() }
        }
        do {
            _ = try await run(session, recognizer)
            XCTFail("the failure was swallowed")
        } catch {
            XCTAssertTrue(error is EngineFailure, "\(error)")
        }
        XCTAssertFalse(session.document.hasChanges)
        XCTAssertFalse(session.canUndo)
    }

    func test_resolutionOutsideTheRangeIsRefused() async throws {
        for dpi in [10, 71, 601, Double.nan] {
            let session = try PdfEditSession.open(OcrKit.scanBytes())
            do {
                _ = try await run(session, FakeRecognizer(OcrKit.words()), OcrOptions(dpi: dpi))
                XCTFail("dpi \(dpi) was taken")
            } catch {
                XCTAssertTrue(error is ArgumentException, "dpi \(dpi): \(error)")
            }
        }
    }

    func test_encryptedFileKeepsItsEncryptionAndTakesTheLayer() async throws {
        for strength in [PdfCryptStrength.aes256, PdfCryptStrength.aes128] {
            let id = [UInt8](repeating: 0, count: 16)
            let security = PdfSecurity.create(userPassword: "user", ownerPassword: "owner", permissions: .all, strength: strength, firstId: id)
            let locked = try OcrKit.scan(2).saveRewrite(PdfSaveOptions(security: security, documentId: id))
            let session = try PdfEditSession.open(locked, password: "user")
            let result = try await run(session, FakeRecognizer(OcrKit.words()))
            XCTAssertEqual(result.added, 2, "\(strength)")

            let saved = session.current
            XCTAssertThrowsError(try PdfDocument.open(saved, password: "wrong")) { XCTAssertTrue($0 is PdfReadException, "\($0)") }
            let reopened = try PdfDocument.open(saved, password: "user")
            XCTAssertTrue(reopened.isEncrypted)
            OcrKit.assertAtBoxes(reopened, 0)
            OcrKit.assertAtBoxes(reopened, 1)
            XCTAssertFalse(OcrKit.latin(saved).contains("Hello"), "\(strength)")
        }
    }

    func test_damagedPagesDoNotStopTheRun() async throws {
        let session = try PdfEditSession.open(OcrKit.scanBytes(2, "", "q 400 0 0 600 0 0 cm /Im1 Do Q [ ( BI ID"))
        let result = try await run(session, FakeRecognizer(OcrKit.words()))
        XCTAssertEqual(result.added, 2)
    }
}
