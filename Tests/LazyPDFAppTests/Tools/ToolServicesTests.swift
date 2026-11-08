import XCTest
@testable import LazyPDFApp

// The file panels, the exporter and the pasteboard a tool asks the host for. Windows tools open their own dialogs, so there is
// no Windows test; the shells' real panels are not run in a test.

@MainActor
private final class StubServices: ToolFilePicker, ToolFileExporter, ToolClipboard {
    var exported: [[URL]] = []

    func pickFiles(_ kinds: [ToolFileKind], multiple: Bool) async -> [ToolFile] { [ToolFile(url: URL(fileURLWithPath: "/tmp/a.pdf"))] }
    func pickFolder() async -> ToolFile? { ToolFile(url: URL(fileURLWithPath: "/tmp")) }

    func export(_ files: [URL]) async -> [URL] {
        exported.append(files)
        return files
    }

    func pictureFile() -> [UInt8]? { [1, 2, 3] }
    func text() -> String? { "pasted" }
}

@MainActor
final class ToolServicesTests: XCTestCase {
    func test_aHostWithNoServicesChoosesNothingSavesNothingAndHasAnEmptyPasteboard() async {
        let host = RecordingHost()

        let files = await host.filePicker.pickFiles([.pdf, .picture], multiple: true)
        let folder = await host.filePicker.pickFolder()
        let saved = await host.fileExporter.export([URL(fileURLWithPath: "/tmp/a.pdf")])

        XCTAssertTrue(files.isEmpty)
        XCTAssertNil(folder)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertNil(host.clipboard.pictureFile())
        XCTAssertNil(host.clipboard.text())
    }

    func test_theViewModelHandsToolsTheServicesTheShellSet() async {
        let f = ViewModelFixture(self)
        let services = StubServices()

        f.vm.filePicker = services
        f.vm.fileExporter = services
        f.vm.clipboard = services

        let files = await f.vm.filePicker.pickFiles([.certificate], multiple: false)
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["a.pdf"])
        let saved = await f.vm.fileExporter.export([URL(fileURLWithPath: "/tmp/b.pdf")])
        XCTAssertEqual(saved.map(\.lastPathComponent), ["b.pdf"])
        XCTAssertEqual(f.vm.clipboard.text(), "pasted")
        XCTAssertEqual(f.vm.clipboard.pictureFile() ?? [], [1, 2, 3])
    }

    func test_aHostWritesOverAnOpenFileInPlaceUnlessTheShellSaysOtherwise() {
        XCTAssertTrue(RecordingHost().fileWriter is PlainFileWriter)
    }
}
