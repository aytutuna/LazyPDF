import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Pages/PageCorpusTests.cs: runs the page tools over every file in a list when
// LAZYPDF_CORPUS names a text file of paths (one per line); without it, over the files of Tests/Fixtures/Documents and
// Tests/Fixtures/Pages (plain, link and form files of several pages; the documents are encrypted or have one page), and then
// something must have been opened, edited and merged. Each result must reopen with the page count the edit calls for.
// Only counts are printed.

final class PageCorpusTests: XCTestCase {
    private func files() -> (paths: [String], fixtures: Bool) {
        if let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            return (text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, false)
        }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        var paths: [String] = []
        for folder in ["Documents", "Pages"].map({ fixtures.appendingPathComponent($0) }) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            paths += names.filter { $0.hasSuffix(".pdf") }.sorted().map { folder.appendingPathComponent($0).path }
        }
        return (paths, true)
    }

    private func reopens(_ document: PdfDocument, _ pages: Int) throws {
        let again = try PdfDocument.open(try document.saveRewrite())
        XCTAssertEqual(again.pages.count, pages)
        XCTAssertEqual(again.repairs, [])
    }

    func test_everyFileSurvivesTheEdits() throws {
        var tried = 0, refused = 0, extracted = 0, edited = 0, merged = 0
        var problems: [String] = []
        var previous: PdfDocument?
        let (paths, fixtures) = files()
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let document: PdfDocument
            do {
                document = try PdfDocument.open(path: path)
            } catch is PdfReadException {
                refused += 1
                continue
            }
            tried += 1
            let count = document.pages.count
            if count == 0 { continue }
            var step = "extract"
            do {
                let first = try PageAssembly.extract(document, Array(0..<min(count, 3)))
                try reopens(first, min(count, 3))
                extracted += 1

                if count > 1 {
                    step = "edit"
                    let copy = try PdfDocument.open(path: path)
                    PageOperations.rotate(copy, [0], 90)
                    try PageOperations.move(copy, [count - 1], 0)
                    try PageOperations.delete(copy, [1])
                    try PageOperations.duplicate(copy, [0])
                    try PageOperations.insertBlank(copy, 0, 200, 200)
                    try reopens(copy, count + 1)
                    edited += 1

                    step = "session"
                    let session = try PdfEditSession.open(path: path)
                    try PageOperations.delete(session.document, [0])
                    PageOperations.rotate(session.document, [0], 90)
                    XCTAssertTrue(try session.commit("Edit"), path)
                    XCTAssertEqual(try PdfDocument.open(session.current).pages.count, count - 1, path)
                    XCTAssertTrue(try session.undo(), path)
                    XCTAssertEqual(session.document.pages.count, count, path)
                }

                if let previous {
                    step = "merge"
                    let both = try PageAssembly.merge([MergeSource(previous, [0]), MergeSource(document, [0])])
                    try reopens(both, 2)
                    merged += 1
                }
                previous = document
            } catch {
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                problems.append("\(step): \(error) (\(size) bytes)")
            }
        }
        print("opened \(tried), refused \(refused), extracted \(extracted), edited \(edited), merged \(merged), problems \(problems.count)")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        if fixtures {
            XCTAssertGreaterThan(tried, 0)
            XCTAssertGreaterThan(extracted, 0)
            XCTAssertGreaterThan(edited, 0)
            XCTAssertGreaterThan(merged, 0)
        }
    }
}
