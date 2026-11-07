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

    func test_aFileWithoutWritePermissionIsNotReplaced() throws {
        let folder = scratch(self)
        let url = folder.appendingPathComponent("a.pdf")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        XCTAssertThrowsError(try CoordinatedFileWriter().write(to: url) { try Data("new".utf8).write(to: $0) }) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    }

    func test_rewriteReadsBackWithAndWithoutObjectStreams() throws {
        var report: [String] = []
        for streams in [false, true] {
            let out = try PdfDocument.open(samplePdf()).saveRewrite(PdfSaveOptions(useObjectStreams: streams))
            do {
                let back = try PdfDocument.open(out)
                report.append("streams=\(streams) ok pages=\(back.pages.count) repairs=\(back.repairs)")
            } catch {
                let text = String(decoding: (out.prefix(1200) + out.suffix(700)).map { $0 >= 32 && $0 < 127 || $0 == 10 ? $0 : 46 }, as: UTF8.self)
                report.append("streams=\(streams) \(error) length=\(out.count) \(text)")
            }
        }
        XCTAssertFalse(report.contains { !$0.contains(" ok ") }, report.joined(separator: " | "))
    }

    func test_compactStepsReport() throws {
        var report: [String] = []
        func step(_ name: String, _ body: () throws -> String) {
            do { report.append("\(name) ok \(try body())") } catch { report.append("\(name) FAILED \(error)") }
        }
        let folder = scratch(self)
        step("rewrite of a session") {
            let session = try PdfEditSession.open(samplePdf())
            let out = try session.document.saveRewrite(PdfSaveOptions(useObjectStreams: true, security: session.document.security))
            return "pages=\(try PdfDocument.open(out).pages.count) length=\(out.count)"
        }
        step("session compact to a plain path") {
            let session = try PdfEditSession.open(samplePdf())
            try session.saveCompact(folder.appendingPathComponent("p.pdf").path)
            return "done"
        }
        step("tab compact with the plain writer") {
            let tab = DocumentTab(session: try PdfEditSession.open(samplePdf()), renderer: StubRenderer(), url: folder.appendingPathComponent("q.pdf"),
                                  title: "q.pdf", writer: PlainFileWriter())
            try tab.saveCompact(folder.appendingPathComponent("r.pdf"))
            return "done"
        }
        step("tab compact twice") {
            let session = try PdfEditSession.open(samplePdf())
            try session.saveCompact(folder.appendingPathComponent("s.pdf").path)
            try session.saveCompact(folder.appendingPathComponent("t.pdf").path)
            return "done"
        }
        XCTAssertFalse(report.contains { $0.contains("FAILED") }, report.joined(separator: " | "))
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

    func test_saveCompactWritesTheFileAndMovesTheTabToIt() throws {
        let folder = scratch(self)
        let tab = try open(folder.appendingPathComponent("a.pdf"))
        let compact = folder.appendingPathComponent("c.pdf")

        try tab.saveCompact(compact)

        XCTAssertEqual(try names(folder), ["c.pdf"])
        XCTAssertEqual(try PdfDocument.open(path: compact.path).pages.count, 1)
        XCTAssertEqual(tab.url, compact)
    }

    func test_saveAsWritesTheNewFileAndMovesTheTabToIt() throws {
        let folder = scratch(self)
        let tab = try open(folder.appendingPathComponent("a.pdf"))
        let copy = folder.appendingPathComponent("b.pdf")

        try tab.saveAs(copy)

        XCTAssertEqual(try names(folder), ["b.pdf"])
        XCTAssertEqual(try PdfDocument.open(path: copy.path).pages.count, 1)
        XCTAssertEqual(tab.url, copy)
    }
}
