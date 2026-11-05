import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/SaveCorpusTests.cs: with LAZYPDF_CORPUS naming a text file of paths
// (one per line), every file that opens is rewritten, with and without object streams, and updated incrementally
// with a changed title; the results must reopen with the same page count and the same page contents. When
// LAZYPDF_CORPUS_OUT names a folder the results are left there for other readers to check.

final class SaveCorpusTests: XCTestCase {
    private static let maxPages = 200
    private static let newTitle = "Changed by the corpus test"

    private func contents(_ document: PdfDocument) -> [[UInt8]] {
        document.pages.prefix(Self.maxPages).map { $0.contents() }
    }

    func test_everyFileSurvivesARewriteAndAnUpdate() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let list = environment["LAZYPDF_CORPUS"], !list.isEmpty, FileManager.default.fileExists(atPath: list) else { return }
        let keep = environment["LAZYPDF_CORPUS_OUT"].flatMap { $0.isEmpty ? nil : $0 }
        if let keep { try FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true) }

        var checkedFiles = 0
        var failures: [String] = []
        let paths = try String(contentsOfFile: list, encoding: .utf8).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        for path in paths {
            let document: PdfDocument
            do {
                document = try PdfDocument.open(path: path)
            } catch is PdfReadException {
                continue
            }
            let name = String(format: "%04d", checkedFiles)
            do {
                let pages = document.pages.count
                let expected = contents(document)
                let source = document.source

                for packed in [false, true] {
                    let rewritten = try document.saveRewrite(PdfSaveOptions(useObjectStreams: packed, security: document.security))
                    check(try PdfDocument.open(rewritten), pages, expected, packed ? "packed rewrite" : "rewrite", path, &failures)
                    if let keep {
                        try Data(rewritten).write(to: URL(fileURLWithPath: keep).appendingPathComponent("\(name)-rewrite\(packed ? "-packed" : "").pdf"))
                    }
                }

                var info = document.info
                if info == nil {
                    let made = PdfDictionary()
                    document.trailer["Info"] = try document.add(made)
                    info = made
                }
                info?["Title"] = PdfString(bytes: Array(Self.newTitle.utf8), isHex: false)
                let updated = try document.saveIncremental()
                if Array(updated[0..<source.count]) != source { failures.append("\(path): the update changed the original bytes") }
                let again = try PdfDocument.open(updated)
                check(again, pages, expected, "update", path, &failures)
                if SaveFixtures.title(again) != Self.newTitle { failures.append("\(path): the new title was not read back") }
                if let keep { try Data(updated).write(to: URL(fileURLWithPath: keep).appendingPathComponent("\(name)-update.pdf")) }
                checkedFiles += 1
            } catch {
                failures.append("\(path): \(error)")
            }
        }
        print("checked \(checkedFiles) files, \(failures.count) failures")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func check(_ written: PdfDocument, _ pages: Int, _ expected: [[UInt8]], _ what: String, _ path: String, _ failures: inout [String]) {
        if written.pages.count != pages {
            failures.append("\(path): \(what) has \(written.pages.count) pages, not \(pages)")
            return
        }
        let back = contents(written)
        for i in 0..<back.count where back[i] != expected[i] {
            failures.append("\(path): \(what) changed the contents of page \(i + 1)")
            return
        }
    }
}
