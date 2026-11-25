import XCTest
@testable import LazyPDFApp

// Mirrors windows/LazyPDF.App.Tests/StoreFilesTests.cs: the settings files, lenient decoding, a file that does not decode
// moved aside.

final class StoreFilesTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    func test_preferencesAreReadBackAsWritten() {
        let dir = TempDir(self)
        AppPreferencesStore.update(dir.url) {
            $0.appearance = .dark
            $0.sidePanel = "layers"
            $0.inspectorSections["stamps"] = true
        }

        let loaded = AppPreferencesStore.load(dir.url)

        XCTAssertEqual(loaded.appearance, .dark)
        XCTAssertEqual(loaded.sidePanel, "layers")
        XCTAssertEqual(loaded.inspectorSections["stamps"], true)
    }

    func test_noFileGivesTheDefaults() {
        let dir = TempDir(self)

        let loaded = AppPreferencesStore.load(dir.url)

        XCTAssertEqual(loaded.appearance, .system)
        XCTAssertEqual(loaded.sidePanel, "pages")
    }

    func test_keysAreWrittenInCamelCaseAndEnumsAsWords() throws {
        let dir = TempDir(self)
        AppPreferencesStore.update(dir.url) { $0.appearance = .light }

        let json = try String(contentsOf: dir.sub("preferences.json"), encoding: .utf8)

        XCTAssertTrue(json.contains("\"appearance\" : \"light\""))
        XCTAssertTrue(json.contains("\"sidePanel\""))
    }

    func test_oneBadValueResetsOnlyThatValue() {
        let dir = TempDir(self)
        dir.file("preferences.json", bytes("{\"appearance\":\"purple\",\"sidePanel\":\"search\",\"inspectorSections\":{\"a\":\"yes\"}}"))

        let loaded = AppPreferencesStore.load(dir.url)

        XCTAssertEqual(loaded.appearance, .system)
        XCTAssertEqual(loaded.sidePanel, "search")
        XCTAssertTrue(loaded.inspectorSections.isEmpty)
    }

    func test_aMissingKeyKeepsItsDefaultAndAnUnknownKeyIsIgnored() {
        let dir = TempDir(self)
        dir.file("preferences.json", bytes("{\"appearance\":\"dark\",\"somethingNew\":1}"))

        let loaded = AppPreferencesStore.load(dir.url)

        XCTAssertEqual(loaded.appearance, .dark)
        XCTAssertEqual(loaded.sidePanel, "pages")
    }

    func test_aFileThatDoesNotDecodeIsMovedAside() throws {
        let dir = TempDir(self)
        dir.file("preferences.json", bytes("not json at all"))

        let loaded = AppPreferencesStore.load(dir.url)

        XCTAssertEqual(loaded.appearance, .system)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.sub("preferences.json").path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        XCTAssertEqual(kept.filter { $0.hasPrefix("preferences.unreadable-") && $0.hasSuffix(".json") }.count, 1)
    }

    func test_updateChangesOnlyTheFieldItIsGiven() {
        let dir = TempDir(self)
        AppPreferencesStore.update(dir.url) { $0.appearance = .dark }
        AppPreferencesStore.update(dir.url) { $0.sidePanel = "" }

        let loaded = AppPreferencesStore.load(dir.url)

        XCTAssertEqual(loaded.appearance, .dark)
        XCTAssertEqual(loaded.sidePanel, "")
    }

    func test_theDefaultFolderIsLazyPdfInApplicationSupport() {
        XCTAssertEqual(StoreFiles.defaultDirectory.lastPathComponent, "Lazy PDF")
        XCTAssertEqual(StoreFiles.defaultDirectory, DefaultAppFolders().settings)
    }

    func test_theDefaultFoldersAreSeparateAndNamedForTheApp() {
        let folders = DefaultAppFolders()

        XCTAssertEqual(folders.recovery.lastPathComponent, "Recovery")
        XCTAssertEqual(folders.recovery.deletingLastPathComponent(), folders.settings)
        XCTAssertEqual(folders.thumbnails.deletingLastPathComponent().lastPathComponent, "Lazy PDF")
        XCTAssertNotEqual(folders.thumbnails.deletingLastPathComponent(), folders.settings)
    }
}
