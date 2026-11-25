import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactCorpusTests.cs: the same case, without the read by PdfPig. Redacts one
// word on each of the first pages of every file in the list LAZYPDF_CORPUS names (one path per line) and checks the word is
// gone, the other words are the same and the output reopens. Skipped without the variable; only counts are printed.

final class RedactCorpusTests: XCTestCase {
    private let maxPages = 25

    func test_oneWordPerPageIsGoneAndTheRestStays() throws {
        guard let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty, FileManager.default.fileExists(atPath: list) else {
            throw XCTSkip("LAZYPDF_CORPUS names no list.")
        }
        var files = 0, skipped = 0, pages = 0, gone = 0, same = 0, reopened = 0, flattened = 0, kept = 0
        var failures: [String] = []
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for path in paths {
            if !FileManager.default.fileExists(atPath: path) { continue }
            files += 1
            do {
                let document = try PdfDocument.open(path: path)
                if document.pages.count == 0 { continue }
                var marks: [RedactionMark] = []
                var before: [Int: (words: [String], target: String)] = [:]
                for p in 0..<min(maxPages, document.pages.count) {
                    let text = TextPage.create(document, document.pages[p])
                    let words = text.words.filter { $0.text.utf16.count >= 4 && $0.text.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil } }
                    if words.isEmpty { continue }
                    let word = words[words.count / 2]
                    marks.append(RedactionMark(p, text.quads(word.range)))
                    before[p] = (text.words.map { $0.text }, word.text)
                }
                if marks.isEmpty { continue }

                let result = try PdfRedactor(document).apply(marks, RedactionKit.drawing(document))
                flattened += result.report.flattened.count
                let again = try PdfDocument.open(result.bytes)
                reopened += 1

                for mark in marks {
                    pages += 1
                    let after = TextPage.create(again, again.pages[mark.page])
                    let areas = mark.quads.map { MarkArea.of($0) }
                    let inside = after.chars.contains { c in !c.isSpace && areas.contains { Geometry.glyphMeets(Geometry.corners(c.quad), $0) } }
                    if inside {
                        failures.append("file \(files) page \(mark.page + 1): text left under the mark")
                    } else {
                        gone += 1
                    }
                    if result.report.flattened.contains(mark.page) { continue }
                    kept += 1
                    guard let entry = before[mark.page] else { continue }
                    var expected = entry.words
                    if let at = expected.firstIndex(of: entry.target) { expected.remove(at: at) }
                    let left = after.words.map { $0.text }
                    let order: (String, String) -> Bool = { $0.utf16.lexicographicallyPrecedes($1.utf16) }
                    if expected.sorted(by: order) == left.sorted(by: order) { same += 1 }
                }
            } catch is PdfReadException {
                skipped += 1
            } catch {
                failures.append("file \(files): \(error)")
            }
        }
        print("\(files) files, \(skipped) skipped, \(reopened) redacted and reopened, \(pages) pages: word gone on \(gone), other words the same on \(same) of \(kept) pages not flattened, \(flattened) pages flattened, \(failures.count) failures")
        XCTAssertTrue(failures.isEmpty, failures.prefix(20).joined(separator: "\n"))
        XCTAssertTrue(Double(same) >= Double(kept) * 0.9, "other words the same on \(same) of \(kept) pages")
    }
}
