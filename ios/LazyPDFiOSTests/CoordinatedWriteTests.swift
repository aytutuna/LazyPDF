import XCTest
import LazyPDFKit
import LazyPDFApp
import LazyPDFIOS

// The coordinated writer behind DocumentTab's save, save as and save compact (Tests/LazyPDFAppTests/Shell/FileWriterTests).

@MainActor
final class CoordinatedWriteTests: XCTestCase {
    private func open(_ url: URL) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(samplePdf()), renderer: StubRenderer(), url: url, title: url.lastPathComponent,
                    writer: CoordinatedFileWriter())
    }

    private func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func test_theBytesReplaceTheFileWhereItLies() throws {
        let folder = scratch(self)
        let url = folder.appendingPathComponent("a.pdf")
        try Data("old".utf8).write(to: url)

        try CoordinatedFileWriter().write(to: url) { try Data("new".utf8).write(to: $0) }

        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertEqual(try names(folder), ["a.pdf"])
    }

    func test_aFileThatIsNotThereYetIsCreated() throws {
        let folder = scratch(self)
        let url = folder.appendingPathComponent("new.pdf")

        try CoordinatedFileWriter().write(to: url) { try Data("bytes".utf8).write(to: $0) }

        XCTAssertEqual(try Data(contentsOf: url), Data("bytes".utf8))
    }

    func test_aFailedWriteLeavesTheFileAsItWas() throws {
        let folder = scratch(self)
        let url = folder.appendingPathComponent("a.pdf")
        try Data("old".utf8).write(to: url)

        XCTAssertThrowsError(try CoordinatedFileWriter().write(to: url) { _ in throw CocoaError(.fileWriteUnknown) })

        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
        XCTAssertEqual(try names(folder), ["a.pdf"])
    }

    func test_saveWritesTheBytesAndKeepsTheFileInPlace() throws {
        let folder = scratch(self)
        let url = folder.appendingPathComponent("a.pdf")
        try Data(try samplePdf("Old text.")).write(to: url)
        let tab = try open(url)

        try tab.save()

        XCTAssertEqual(try names(folder), ["a.pdf"])
        XCTAssertEqual(tab.url, url)
        XCTAssertEqual(try PdfDocument.open(path: url.path).pages.count, 1)
        XCTAssertFalse(tab.isDirty)
    }

    func test_saveAsAndSaveCompactWriteTheirFiles() throws {
        let folder = scratch(self)
        let url = folder.appendingPathComponent("a.pdf")
        let tab = try open(url)
        let copy = folder.appendingPathComponent("b.pdf")
        let compact = folder.appendingPathComponent("c.pdf")

        try tab.saveAs(copy)
        try tab.saveCompact(compact)

        XCTAssertEqual(try names(folder), ["b.pdf", "c.pdf"])
        XCTAssertEqual(try PdfDocument.open(path: copy.path).pages.count, 1)
        XCTAssertEqual(try PdfDocument.open(path: compact.path).pages.count, 1)
        XCTAssertEqual(tab.url, compact)
    }
}
