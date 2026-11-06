import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactCorpusMetadataTests.cs: the same case. Redacts one word on each of the
// first pages of every file in the list LAZYPDF_CORPUS names, with the metadata changed too. Skipped without the variable;
// only counts are printed.

final class RedactCorpusMetadataTests: XCTestCase {
    private let maxPages = 25

    // Only what the check could not read: no text found, and the pages it could not follow are not marked.
    private func notChecked(_ problem: String, _ marks: [RedactionMark]) -> Bool {
        problem.hasSuffix("so it was not checked.") || (problem.hasPrefix("Page ") && !marks.contains { problem == RedactionText.notFollowed($0.page) })
    }

    func test_outputOfEveryFileVerifiesCleanExceptAttachments() throws {
        guard let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty, FileManager.default.fileExists(atPath: list) else {
            throw XCTSkip("LAZYPDF_CORPUS names no list.")
        }
        var files = 0, clean = 0, attachments = 0, unread = 0, refused = 0, flattened = 0
        var dirty: [String] = []
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for path in paths {
            if !FileManager.default.fileExists(atPath: path) { continue }
            do {
                let document = try PdfDocument.open(path: path)
                var marks: [RedactionMark] = []
                for p in 0..<min(maxPages, document.pages.count) {
                    let text = TextPage.create(document, document.pages[p])
                    let words = text.words.filter { $0.text.utf16.count >= 4 && $0.text.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil } }
                    if !words.isEmpty { marks.append(RedactionMark(p, text.quads(words[words.count / 2].range))) }
                }
                if marks.isEmpty { continue }
                files += 1
                var options = RedactionOptions()
                options.changeMetadata = true
                let result = try PdfRedactor(document).apply(marks, RedactionKit.drawing(document, options))
                flattened += result.report.flattened.count
                let problems = result.verification.problems
                if problems.isEmpty {
                    clean += 1
                } else if problems.allSatisfy({ $0.contains("attached file") }) {
                    attachments += 1
                } else if problems.allSatisfy({ notChecked($0, marks) }) {
                    unread += 1
                } else {
                    dirty.append("file \(files): \(problems.count) problems")
                }
            } catch is PdfReadException {
            } catch is InvalidOperationException {
                refused += 1
            }
        }
        print("\(files) files redacted: \(clean) clean, \(attachments) with the word in an attachment only, \(unread) not fully checked, \(dirty.count) not clean, \(refused) refused, \(flattened) pages flattened")
        XCTAssertTrue(dirty.isEmpty, dirty.prefix(20).joined(separator: "\n"))
    }
}
