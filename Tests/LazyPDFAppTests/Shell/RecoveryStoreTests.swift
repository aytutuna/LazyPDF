import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/RecoveryStoreTests.cs: the recovery folder, what each open document left after its last
// edit.

final class RecoveryStoreTests: XCTestCase {
    private func meta(_ title: String, _ path: String? = nil) -> RecoveryMeta {
        RecoveryMeta(title: title, originalPath: path, saved: Date())
    }

    func test_aWrittenDocumentIsListedWithItsBytesAndFacts() throws {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.url)
        let id = UUID()

        store.write(id, [1, 2, 3], meta("a.pdf", "/docs/a.pdf"))
        store.flush()

        let entries = store.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, id)
        XCTAssertEqual(entries[0].meta.title, "a.pdf")
        XCTAssertEqual(entries[0].meta.originalPath, "/docs/a.pdf")
        XCTAssertEqual([UInt8](try Data(contentsOf: entries[0].pdf)), [1, 2, 3])
    }

    func test_aNewerWriteReplacesTheOlderOne() throws {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.url)
        let id = UUID()

        store.write(id, [1], meta("a.pdf"))
        store.write(id, [1, 2], meta("a.pdf"))
        store.flush()

        let entries = store.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual([UInt8](try Data(contentsOf: entries[0].pdf)), [1, 2])
    }

    func test_deleteTakesTheDocumentOut() {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.url)
        let id = UUID()
        store.write(id, [1], meta("a.pdf"))

        store.delete(id)

        XCTAssertTrue(store.list().isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.url.path)) ?? []
        XCTAssertTrue(left.isEmpty)
    }

    func test_aDocumentDeletedBeforeItWasWrittenLeavesNothing() {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.url)
        let id = UUID()

        for _ in 0..<20 { store.write(id, [UInt8](repeating: 0, count: 100_000), meta("a.pdf")) }
        store.delete(id)

        XCTAssertTrue(store.list().isEmpty)
    }

    func test_theNewestIsListedFirst() {
        let dir = TempDir(self)
        let store = RecoveryStore(directory: dir.url)
        store.write(UUID(), [1], RecoveryMeta(title: "old", saved: Date().addingTimeInterval(-7200)))
        store.write(UUID(), [1], RecoveryMeta(title: "new", saved: Date()))
        store.flush()

        XCTAssertEqual(store.list().map(\.meta.title), ["new", "old"])
    }

    func test_aFolderThatIsNotThereListsNothing() {
        let dir = TempDir(self)

        XCTAssertTrue(RecoveryStore(directory: dir.sub("none")).list().isEmpty)
    }

    func test_aStrayFileIsNotADocument() {
        let dir = TempDir(self)
        dir.file("notes.json", [1])
        dir.file(UUID().uuidString + ".json", [1])

        XCTAssertTrue(RecoveryStore(directory: dir.url).list().isEmpty)
    }
}
