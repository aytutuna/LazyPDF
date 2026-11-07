import XCTest
import LazyPDFKit
@testable import LazyPDFApp

// No Windows twin, see FileWriter.swift: a tab writes every save through its file writer.

/// Writes into a staging folder first, as the coordinated writer of iOS does, and notes where each file was meant to go.
private final class StagingWriter: FileWriter {
    private let staging: URL
    private(set) var targets: [URL] = []
    private(set) var staged: [URL] = []

    init(_ staging: URL) {
        self.staging = staging
    }

    func write(to url: URL, _ write: (URL) throws -> Void) throws {
        let work = staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent(url.lastPathComponent)
        try write(file)
        targets.append(url)
        staged.append(file)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: file, to: url)
    }
}

@MainActor
final class FileWriterTests: XCTestCase {
    private func open(_ url: URL, _ writer: FileWriter) throws -> DocumentTab {
        DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: url, title: "a.pdf", writer: writer)
    }

    func test_thePlainWriterWritesAtTheUrlItself() throws {
        let dir = TempDir(self)
        let target = dir.sub("a.pdf")
        var seen: URL?

        try PlainFileWriter().write(to: target) { seen = $0 }

        XCTAssertEqual(seen, target)
    }

    func test_saveGoesThroughTheWriterAndTheFileStaysWhereItWas() throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        let writer = StagingWriter(dir.sub("stage"))
        let tab = try open(file, writer)
        try Pdfs.retitle(tab.session, "Changed")
        try tab.commit("Properties")

        try tab.save()

        XCTAssertEqual(writer.targets.map(\.path), [file.path])
        XCTAssertNotEqual(writer.staged.first, file)
        XCTAssertEqual(DocumentMetadata.read(try PdfDocument.open(path: file.path)).title, "Changed")
        XCTAssertFalse(tab.isDirty)
    }

    func test_saveAsAndSaveCompactGoThroughTheWriterToo() throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        let writer = StagingWriter(dir.sub("stage"))
        let tab = try open(file, writer)
        let copy = dir.sub("b.pdf")
        let compact = dir.sub("c.pdf")

        try tab.saveAs(copy)
        try tab.saveCompact(compact)

        XCTAssertEqual(writer.targets.map(\.lastPathComponent), ["b.pdf", "c.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: compact.path))
        XCTAssertEqual(tab.url?.lastPathComponent, "c.pdf")
    }

    func test_aTabWithNoWriterGivenSavesInPlace() throws {
        let dir = TempDir(self)
        let file = dir.file("a.pdf", Pdfs.text())
        let tab = DocumentTab(session: try PdfEditSession.open(Pdfs.text()), renderer: FakeRenderer(), url: file, title: "a.pdf")
        try Pdfs.retitle(tab.session, "Plain")
        try tab.commit("Properties")

        try tab.save()

        XCTAssertEqual(DocumentMetadata.read(try PdfDocument.open(path: file.path)).title, "Plain")
    }
}
