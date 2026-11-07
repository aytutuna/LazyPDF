#if os(macOS)
import XCTest
import UniformTypeIdentifiers
@testable import LazyPDFMac
import LazyPDFApp

// Not in the Windows tests: the folders of the sandbox container, the lookup of the sister apps and the panels.

final class MacAppFoldersTests: XCTestCase {
    private let folders = MacAppFolders(support: URL(fileURLWithPath: "/s"), caches: URL(fileURLWithPath: "/c"), temporary: URL(fileURLWithPath: "/t"))

    func test_settingsAndRecoverySitInApplicationSupport() {
        XCTAssertEqual(folders.settings.path, "/s/Lazy PDF")
        XCTAssertEqual(folders.recovery.path, "/s/Lazy PDF/Recovery")
    }

    func test_thumbnailsAndPrintCopiesSitInTheCaches() {
        XCTAssertEqual(folders.thumbnails.path, "/c/Lazy PDF/Thumbnails")
        XCTAssertEqual(folders.printCopies.path, "/c/Lazy PDF/Print")
    }

    func test_openedAttachmentsSitInTheTemporaryFolder() {
        XCTAssertEqual(folders.openedAttachments.path, "/t/Lazy PDF/Attachments")
    }

    func test_theSystemFoldersAreNamedAfterTheApp() {
        let system = MacAppFolders()

        XCTAssertEqual(system.settings.lastPathComponent, "Lazy PDF")
        XCTAssertTrue(system.printCopies.path.contains("Caches"))
    }
}

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
#endif
