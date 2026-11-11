import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/Tools/ocr/OcrWorkTests.cs: the panel's actions on a real tab and the real window state, with
// a recognizer that returns fixed words. The Windows InlineContext is not needed: progress reaches the busy bar through the main
// actor in order.

/// What a test hears, from the task the recognizer runs on.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class FakeRecognizer: TextRecognizer, @unchecked Sendable {
    var words = ["alpha", "beta"]
    var fails: Error?
    var onRead: (@Sendable () async -> Void)?
    private let languageLog = Log()

    var languages: [String] { languageLog.all }

    func recognizeAsync(_ image: PdfRgbaImage, _ language: String) async throws -> [OcrWord] {
        await onRead?()
        try Task.checkCancellation()
        if let fails { throw fails }
        languageLog.add(language)
        return words.enumerated().map { OcrWord($0.element, OcrBox(0, Double($0.offset), Double(image.width), 1)) }
    }
}

@MainActor
final class OcrWorkTests: XCTestCase {
    private func open(_ f: ViewModelFixture, pages: Int = 2) async -> DocumentTab {
        await f.vm.open(f.pdf("a.pdf", pages: pages))
        return f.vm.activeDocument!
    }

    private func all(_ existing: OcrExisting = .skip, language: String = "en-US") -> OcrOptions {
        OcrOptions(language: language, dpi: OcrWork.dpi, existing: existing, pages: [0, 1], force: true)
    }

    private func words(_ tab: DocumentTab, _ page: Int = 0) throws -> [String] {
        try PdfOcrLayer.words(tab.document, tab.document.pages[page]).map(\.text)
    }

    func test_pagesGetALayerAsOneUndoableStep() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let revision = tab.revision
        let recognizer = FakeRecognizer()

        let result = try await OcrWork.makeSearchable(tab, f.vm, recognizer, all(language: "tr-TR"))

        XCTAssertEqual(result?.added, 2)
        XCTAssertTrue(tab.document.pages.allSatisfy { PdfOcrLayer.has(tab.document, $0) })
        XCTAssertEqual(recognizer.languages, ["tr-TR", "tr-TR"])
        XCTAssertEqual(PdfOcrLayer.language(tab.document, tab.document.pages[0]), "tr-TR")
        XCTAssertGreaterThan(tab.revision, revision)
        XCTAssertEqual(f.vm.statusFull, "Made 2 pages searchable")
        XCTAssertEqual(tab.session.undoLabel, "Make searchable")

        XCTAssertTrue(try tab.undo())
        XCTAssertTrue(tab.document.pages.allSatisfy { !PdfOcrLayer.has(tab.document, $0) })
    }

    func test_theWordsOfTheLayerCanBeFoundAgain() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)

        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())

        XCTAssertEqual(try words(tab), ["alpha", "beta"])
    }

    func test_keepingLeavesAnExistingLayerAndReplacingChangesIt() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())
        let gamma = FakeRecognizer()
        gamma.words = ["gamma"]

        let kept = try await OcrWork.makeSearchable(tab, f.vm, gamma, all(.skip))
        XCTAssertEqual(kept?.skipped, 1)
        XCTAssertEqual(try words(tab), ["alpha", "beta"])

        let replaced = try await OcrWork.makeSearchable(tab, f.vm, gamma, all(.replace))
        XCTAssertEqual(replaced?.added, 1)
        XCTAssertEqual(try words(tab), ["gamma"])
    }

    func test_onlyTheChosenPagesAreRead() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 3)

        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), OcrOptions(language: "en-US", dpi: OcrWork.dpi, pages: [1], force: true))

        XCTAssertEqual(tab.document.pages.map { PdfOcrLayer.has(tab.document, $0) }, [false, true, false])
    }

    func test_aCancelLeavesTheDocumentAsItWas() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let vm = f.vm!
        let recognizer = FakeRecognizer()
        recognizer.onRead = {
            await MainActor.run { vm.cancelBusy() }
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
        }

        let result = try await OcrWork.makeSearchable(tab, f.vm, recognizer, all())

        XCTAssertNil(result)
        XCTAssertEqual(f.vm.statusFull, "Cancelled.")
        XCTAssertFalse(tab.session.canUndo)
        XCTAssertFalse(PdfOcrLayer.has(tab.document, tab.document.pages[0]))
    }

    func test_aLanguageTheSystemLacksIsShownAsAProblem() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let recognizer = FakeRecognizer()
        recognizer.fails = InvalidOperationException("This device cannot read xx text.")

        let result = try await OcrWork.makeSearchable(tab, f.vm, recognizer, all(language: "xx"))

        XCTAssertNil(result)
        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(f.vm.message?.title, "Language not available")
        XCTAssertTrue(f.vm.message?.text.contains("xx") == true)
        XCTAssertFalse(tab.session.canUndo)
    }

    func test_pagesThatCouldNotBeDrawnAreSaid() async throws {
        let f = ViewModelFixture(self)
        f.draws = false
        let tab = await open(f)

        let result = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())

        XCTAssertEqual(result?.notRendered, 2)
        XCTAssertEqual(result?.committed, false)
        XCTAssertEqual(f.vm.message?.title, "Not every page was read")
        XCTAssertEqual(f.vm.message?.text, "2 pages could not be drawn.")
    }

    func test_pagesWithoutWordsAreSaidAndNothingIsCommitted() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        let recognizer = FakeRecognizer()
        recognizer.words = []

        _ = try await OcrWork.makeSearchable(tab, f.vm, recognizer, all())

        XCTAssertEqual(f.vm.message?.text, "No text found on 1 page. Check the language. "
            + "Pages that are turned sideways cannot be read. Rotate them in Organize pages first.")
        XCTAssertFalse(tab.session.canUndo)
    }

    func test_theSidewaysSentenceComesLast() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())
        let empty = FakeRecognizer()
        empty.words = []

        _ = try await OcrWork.makeSearchable(tab, f.vm, empty, all(.replace))
        XCTAssertEqual(f.vm.message?.text.hasSuffix("Undo brings it back. Pages that are turned sideways cannot be read. Rotate them in Organize pages first."), true)
    }

    func test_nothingToDoIsSaidInTheStatus() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)

        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), OcrOptions(language: "en-US", dpi: OcrWork.dpi, pages: [0]))

        XCTAssertEqual(f.vm.statusFull, "No pages need text recognition.")
    }

    func test_removingTakesTheLayerOffOnlyWhereItIs() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 2)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), OcrOptions(language: "en-US", dpi: OcrWork.dpi, pages: [0], force: true))

        let removed = try OcrWork.remove(tab, [0, 1])

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(PdfOcrLayer.has(tab.document, tab.document.pages[0]))
        XCTAssertEqual(tab.session.undoLabel, "Remove text layer")
        XCTAssertEqual(try OcrWork.remove(tab, [0, 1]), 0)
    }

    func test_aCorrectionChangesTheWordAndUndoRestoresIt() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())

        try OcrWork.correct(tab, 0, 1, "gamma")

        XCTAssertEqual(try words(tab), ["alpha", "gamma"])
        XCTAssertEqual(tab.session.undoLabel, "Correct word")
        try tab.undo()
        XCTAssertEqual(try words(tab), ["alpha", "beta"])
    }

    func test_anEmptyCorrectionRemovesTheWord() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())

        try OcrWork.correct(tab, 0, 0, "")

        XCTAssertEqual(try words(tab), ["beta"])
    }

    func test_thePageCountReachesTheBusyBar() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let seen = Log()
        let vm = f.vm!
        let recognizer = FakeRecognizer()
        recognizer.onRead = { seen.add(await MainActor.run { vm.busyText }) }

        _ = try await OcrWork.makeSearchable(tab, f.vm, recognizer, all())

        XCTAssertEqual(seen.all, ["Reading pages", "Reading page 1 of 2"])
    }

    func test_aDocumentThatChangedMidRunIsLeftAloneAndSaid() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f)
        let changed = Log()
        let recognizer = FakeRecognizer()
        recognizer.onRead = {
            if !changed.all.isEmpty { return }
            changed.add("once")
            await MainActor.run {
                try? Pdfs.retitle(tab.session, "Other")
                _ = try? tab.commit("Retitle")
            }
        }

        let result = try await OcrWork.makeSearchable(tab, f.vm, recognizer, all())

        XCTAssertNil(result)
        XCTAssertEqual(f.vm.message?.title, "The file changed")
        XCTAssertEqual(tab.session.undoLabel, "Retitle")
        XCTAssertFalse(PdfOcrLayer.has(tab.document, tab.document.pages[0]))
    }

    func test_replacingWithNoWordsSaysTheOldTextWasRemoved() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())
        let empty = FakeRecognizer()
        empty.words = []

        _ = try await OcrWork.makeSearchable(tab, f.vm, empty, all(.replace))

        XCTAssertTrue(f.vm.message?.text.contains("Text read earlier on those pages was removed.") == true)
        XCTAssertEqual(try words(tab), [])
        XCTAssertTrue(try tab.undo())
        XCTAssertEqual(try words(tab), ["alpha", "beta"])
    }

    func test_aPageWithNoLayerBeforeGetsNoSuchSentence() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        let empty = FakeRecognizer()
        empty.words = []

        _ = try await OcrWork.makeSearchable(tab, f.vm, empty, all(.replace))

        XCTAssertFalse(f.vm.message?.text.contains("removed") == true)
    }

    func test_aCorrectionThatChangesNothingAddsNoStep() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())
        let revision = tab.revision

        XCTAssertFalse(try OcrWork.correct(tab, 0, 1, "beta"))

        XCTAssertEqual(tab.revision, revision)
        XCTAssertEqual(tab.session.undoLabel, "Make searchable")
    }

    func test_removingIgnoresPagesThePanelStillListsAfterTheyWereDeleted() async throws {
        let f = ViewModelFixture(self)
        let tab = await open(f, pages: 1)
        _ = try await OcrWork.makeSearchable(tab, f.vm, FakeRecognizer(), all())

        XCTAssertEqual(try OcrWork.remove(tab, [0, 7]), 1)
    }

    func test_aFileThatForbidsChangesIsRefused() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("r.pdf", try Pdfs.restricted(.print)))
        let tab = f.vm.activeDocument!

        let cleared = OcrWork.cleared(tab, f.vm, go: { XCTFail("must not go on") })

        XCTAssertFalse(cleared)
        XCTAssertEqual(f.vm.message?.isError, true)
        XCTAssertEqual(f.vm.message?.title, "This file cannot be changed")
    }

    func test_aFileThatMayBeChangedIsClear() async {
        let f = ViewModelFixture(self)
        let tab = await open(f)

        XCTAssertTrue(OcrWork.cleared(tab, f.vm, go: {}))
        XCTAssertNil(f.vm.message)
    }

    func test_aSignedFileAsksFirstAndGoesOnOnYes() async throws {
        let f = ViewModelFixture(self)
        await f.vm.open(f.dir.file("s.pdf", try Pdfs.signed(certified: false)))
        let tab = f.vm.activeDocument!
        var went = false

        let cleared = OcrWork.cleared(tab, f.vm, go: { went = true })

        XCTAssertFalse(cleared)
        XCTAssertFalse(went)
        XCTAssertEqual(f.vm.message?.title, "Check before going on")
        XCTAssertTrue(f.vm.message?.text.contains("signed") == true)
        f.vm.message?.action?.run()
        XCTAssertTrue(went)
    }
}
