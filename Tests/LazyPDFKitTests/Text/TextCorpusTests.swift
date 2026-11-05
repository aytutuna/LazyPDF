import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Text/TextCorpusTests.cs: runs every page of every file in the list LAZYPDF_CORPUS
// names (one path per line) through the text engine; without it, text-pages.pdf of the text golden folder and the files
// of Tests/Fixtures/Documents that open without a password, and then the run must have opened a file, found text in a
// page and searched for a word of it. Only counts and times are printed. The C# also reports any exception that is not
// a PdfReadException; in Swift such a failure is a trap that ends the run.

final class TextCorpusTests: XCTestCase {
    private let usesCorpus = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"].map { !$0.isEmpty } ?? false

    private func files() -> [String] {
        if let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let folder = fixtures.appendingPathComponent("Documents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return [fixtures.appendingPathComponent("golden/text/text-pages.pdf").path]
            + names.filter { $0.hasSuffix(".pdf") }.sorted().map { folder.appendingPathComponent($0).path }
    }

    func test_everyPageGivesConsistentText() throws {
        var opened = 0, pages = 0, withText = 0, searched = 0, found = 0
        var chars = 0
        var times: [Double] = []
        var problems: [String] = []
        for path in files() where FileManager.default.fileExists(atPath: path) {
            do {
                let document = try PdfDocument.open(path: path)
                opened += 1
                let interpreter = ContentInterpreter(document)
                for pdfPage in document.pages {
                    let started = Date()
                    let page = TextPage.create(interpreter, pdfPage)
                    let elapsed = Date().timeIntervalSince(started) * 1000
                    pages += 1
                    chars += page.chars.count
                    if page.chars.count > 200 { times.append(elapsed) }
                    if page.chars.isEmpty { continue }
                    withText += 1
                    if let problem = TextInvariants.check(page), problems.count < 20 { problems.append(problem) }
                    guard let word = page.words.first(where: { $0.text.utf16.count >= 5 && $0.text.utf16.allSatisfy { $0.isLetter } }) else { continue }
                    searched += 1
                    let hits = try TextSearch.find(page, word.text)
                    if hits.contains(where: { $0.range.start <= word.range.start && $0.range.end >= word.range.end }) { found += 1 }
                }
            } catch is PdfReadException {
            }
        }
        times.sort()
        print("\(opened) files, \(pages) pages (\(withText) with text), \(chars) chars; search found its own word on \(found) of \(searched) pages")
        if let median = times.isEmpty ? nil : times[times.count / 2] {
            print("ms per page: median \(median), max \(times[times.count - 1])")
        }
        if !usesCorpus {
            XCTAssertGreaterThan(opened, 0)
            XCTAssertGreaterThan(withText, 0)
            XCTAssertGreaterThan(searched, 0)
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        XCTAssertTrue(Double(found) >= Double(searched) * 0.99, "search found its own word on \(found) of \(searched) pages")
    }
}
