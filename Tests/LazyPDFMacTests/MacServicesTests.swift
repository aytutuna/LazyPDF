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
        sisters.openLazyScan {}
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
