#if os(macOS)
import XCTest
import UniformTypeIdentifiers
@testable import LazyPDFMac
import LazyPDFApp

// Not in the Windows tests: the lookup of the sister apps and the panels.

final class MacSisterAppsTests: XCTestCase {
    func test_anAppThatIsNotInstalledIsNotFound() {
        let sisters = MacSisterApps(scanId: "test.lazypdf.nothing.scan", printId: "test.lazypdf.nothing.print")

        XCTAssertFalse(sisters.lazyScanInstalled)
        XCTAssertFalse(sisters.tryPrint(URL(fileURLWithPath: "/tmp/a.pdf")))
        sisters.openLazyScan()
    }
}

@MainActor
final class MacFilePanelsTests: XCTestCase {
    func test_theOpenPanelTakesWhatFileKindsTakes() {
        let panel = MacFilePanels.openPanel()
        let types = panel.allowedContentTypes

        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(types.contains(.pdf))
        XCTAssertTrue(types.contains(.png))
        XCTAssertTrue(types.contains(.plainText))
        XCTAssertTrue(types.contains(.heic))
    }

    func test_theSavePanelOffersTheDocumentsNameAsAPdf() {
        let panel = MacFilePanels.savePanel("Save as", name: "letter.pdf", folder: nil)

        XCTAssertEqual(panel.nameFieldStringValue, "letter.pdf")
        XCTAssertEqual(panel.allowedContentTypes, [.pdf])
    }

    func test_aPictureIsOfferedUnderAPdfName() {
        XCTAssertEqual(MacFilePanels.pdfName("photo.png"), "photo.pdf")
        XCTAssertEqual(MacFilePanels.pdfName("notes"), "notes.pdf")
    }

    func test_saveCompactHasATitleOfItsOwn() {
        let panel = MacFilePanels.savePanel("Save compact", name: "a.pdf", folder: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(panel.title, "Save compact")
        XCTAssertEqual(panel.directoryURL?.path, "/tmp")
    }
}

// Not in the Windows tests: Windows writes the parts itself with UniquePath, where the Mac hands them to the exporter.
@MainActor
final class MacToolServicesTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lazypdf-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func test_filesPlacedInAFolderNeverReplaceWhatIsThere() throws {
        let from = try folder(), into = try folder()
        let old = try write("last week", "report 1.pdf", in: into)
        let part1 = try write("new one", "report 1.pdf", in: from)
        let part2 = try write("new two", "report 2.pdf", in: from)

        let placed = MacToolServices.place([part1, part2], in: into)

        XCTAssertEqual(placed.saved.map(\.lastPathComponent), ["report 1 (2).pdf", "report 2.pdf"])
        XCTAssertTrue(placed.unwritten.isEmpty)
        XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "last week")
        XCTAssertEqual(try String(contentsOf: placed.saved[0], encoding: .utf8), "new one")
    }

    func test_aFileThatCannotBeWrittenIsNamed() throws {
        let from = try folder()
        let part = try write("x", "a.pdf", in: from)
        let missing = from.appendingPathComponent("gone", isDirectory: true)

        let placed = MacToolServices.place([part], in: missing)

        XCTAssertTrue(placed.saved.isEmpty)
        XCTAssertEqual(placed.unwritten, ["a.pdf"])
    }
}
#endif
