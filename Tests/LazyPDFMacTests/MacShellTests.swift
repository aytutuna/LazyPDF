#if os(macOS)
import XCTest
import AppKit
@testable import LazyPDFMac
import LazyPDFApp
import LazyPDFKit

// Not in the Windows tests: a sandboxed app is handed a path by an address and may not be able to read it.

final class MacAddressTests: XCTestCase {
    func test_aFileTheAppCanReadIsOpened() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("address-\(UUID().uuidString).pdf")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""

        let files = MacShell.split("lazypdf://open?file=" + encoded)

        XCTAssertEqual(files.readable.map(\.path), [file.path])
        XCTAssertTrue(files.refused.isEmpty)
    }

    func test_aFileThatCannotBeReadIsRefused() {
        let files = MacShell.split("lazypdf://open?file=%2Fno%2Fsuch%2Ffolder%2Fa.pdf&file=%2Fno%2Fb.pdf")

        XCTAssertTrue(files.readable.isEmpty)
        XCTAssertEqual(files.refused.map(\.lastPathComponent), ["a.pdf", "b.pdf"])
    }

    func test_anAddressWithNoFileNamesNothing() {
        let files = MacShell.split("lazypdf:")

        XCTAssertTrue(files.readable.isEmpty)
        XCTAssertTrue(files.refused.isEmpty)
    }
}
@MainActor
final class MacSystemRecentsTests: XCTestCase {
    func test_anOpenedFileIsHandedToTheSystemRecentList() async throws {
        let shell = MacShell.shared
        var noted: [URL] = []
        shell.noteRecent = { noted.append($0) }
        defer { shell.noteRecent = { NSDocumentController.shared.noteNewRecentDocumentURL($0) } }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString).pdf")
        try Data(MacPdfs.text()).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        shell.open([file])
        for _ in 0..<100 where shell.vm.tab(of: file) == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(noted.map(\.lastPathComponent), [file.lastPathComponent])
    }
}

@MainActor
final class MacWindowStateTests: XCTestCase {
    func test_theWindowFollowsTheActiveDocument() async throws {
        let shell = MacShell.shared
        let window = NSWindow()
        shell.attach(window)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("window-\(UUID().uuidString).pdf")
        try Data(MacPdfs.text()).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        await shell.vm.open(file)
        shell.update(WindowState(shell.vm.activeDocument))
        XCTAssertEqual(window.title, file.lastPathComponent)
        XCTAssertEqual(window.representedURL, file)
        XCTAssertFalse(window.isDocumentEdited)

        let tab = try XCTUnwrap(shell.vm.activeDocument)
        var metadata = DocumentMetadata.read(tab.session.document)
        metadata.title = "Changed"
        try metadata.write(tab.session.document)
        try tab.commit("Properties")
        shell.update(WindowState(shell.vm.activeDocument))
        XCTAssertTrue(window.isDocumentEdited)

        shell.vm.close(tab)
        shell.update(WindowState(shell.vm.activeDocument))
        XCTAssertEqual(window.title, "Lazy PDF")
        XCTAssertNil(window.representedURL)
        XCTAssertFalse(window.isDocumentEdited)
    }
}
#endif
