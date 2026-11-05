import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Compare/CorpusCompareTests.cs: compares every file in the list LAZYPDF_CORPUS names (one
// path per line) with itself, and with a copy in which one word of the page content was changed. Without it, text-pages.pdf of
// the text golden folder and the files of Tests/Fixtures/Documents that open without a password are used, and then the run must
// have opened a file. Only counts and times are printed.

final class CorpusCompareTests: XCTestCase {
    private struct Edit {
        let page: Int
        let word: String
        let reversed: String
        let operation: Int
        let element: Int
        let offset: Int
    }

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

    func test_everyFileEqualsItselfAndOneEditedWordIsFound() throws {
        var count = 0, opened = 0, pages = 0, identical = 0, edited = 0, exact = 0
        var failures: [String] = []
        var selfTime = 0.0, editTime = 0.0
        for path in files() where FileManager.default.fileExists(atPath: path) {
            count += 1
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let bytes = [UInt8](data)
            do {
                let a = try PdfDocument.open(bytes)
                let b = try PdfDocument.open(bytes)
                opened += 1
                pages += a.pages.count

                var started = Date()
                let same = try PdfComparer.compare(a, b)
                selfTime += Date().timeIntervalSince(started)
                if same.isIdentical {
                    identical += 1
                } else {
                    let s = same.summary
                    failures.append("\(count): self compare gave \(same.changes.count) changes (\(s.text) text, \(s.format) format, \(s.images) images, \(s.annotations) notes, \(s.pages) pages, \(s.document) document)")
                }

                guard let edit = findEdit(a) else { continue }
                edited += 1
                let changed = try PdfDocument.open(bytes)
                guard apply(changed, edit) else {
                    failures.append("\(count): the edit on page \(edit.page) did not fit the content")
                    continue
                }
                let reopened = try PdfDocument.open(try changed.saveRewrite())
                started = Date()
                let result = try PdfComparer.compare(a, reopened)
                editTime += Date().timeIntervalSince(started)
                if result.changes.count == 1, let change = result.changes.first, change.kind == .changed, change.area == .text,
                   change.oldText == edit.word, change.newText == edit.reversed, change.newPage == edit.page {
                    exact += 1
                } else {
                    let kinds = result.changes.prefix(4).map { "\($0.kind)/\($0.area)" }.joined(separator: ",")
                    failures.append("\(count): edit on page \(edit.page) gave \(result.changes.count) changes (\(kinds))")
                }
            } catch is PdfReadException {
                // Files that need a password or that cannot be read are not part of this test.
            }
        }
        print("files \(count), opened \(opened), pages \(pages)")
        print("self compare: \(identical) identical of \(opened), \(String(format: "%.1f", selfTime)) s")
        print("one word edited: \(edited) files, \(exact) found exactly, \(String(format: "%.1f", editTime)) s")
        for failure in failures.prefix(30) { print(failure) }
        if !usesCorpus { XCTAssertGreaterThan(opened, 0) }
        XCTAssertTrue(failures.isEmpty, failures.prefix(30).joined(separator: "\n"))
    }

    /// The first word of letters only whose glyphs all come from one byte string of a simple font, so that reversing its bytes
    /// gives another word that the font can draw.
    private func findEdit(_ document: PdfDocument) -> Edit? {
        let cache = TextCache(document)
        for p in 0..<document.pages.count {
            let text = cache.get(p)
            for word in text.words {
                let letters = Array(word.text.unicodeScalars)
                let isLetter: (Unicode.Scalar) -> Bool = { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 65 && $0.value <= 90) }
                if word.text.utf16.count < 3 || !letters.allSatisfy(isLetter) || Set(letters).count < 2 { continue }
                let reversed = String(String.UnicodeScalarView(letters.reversed()))
                if reversed == word.text || word.range.count != word.text.utf16.count { continue }
                let chars = (word.range.start..<word.range.end).map { text.chars[$0] }
                guard let first = chars.first else { continue }
                let sameString = chars.allSatisfy { c in
                    c.form == nil && c.font.map { !$0.isComposite && !$0.isType3 } == true && c.operatorIndex == first.operatorIndex
                        && c.element == first.element && !c.isImplied && c.text.utf16.count == 1
                }
                let consecutive = chars.enumerated().allSatisfy { $0.element.offset == first.offset + $0.offset }
                if sameString && consecutive {
                    return Edit(page: p, word: word.text, reversed: reversed, operation: first.operatorIndex, element: first.element, offset: first.offset)
                }
            }
        }
        return nil
    }

    private func apply(_ document: PdfDocument, _ edit: Edit) -> Bool {
        let page = document.pages[edit.page]
        let operations = ContentParser.parse(page.contents())
        guard edit.operation >= 0, edit.operation < operations.count, let operand = operations[edit.operation].operands.first else { return false }
        let target: PdfString?
        if let array = operand as? PdfArray {
            target = edit.element >= 0 && edit.element < array.items.count ? array.items[edit.element] as? PdfString : nil
        } else {
            target = operand as? PdfString
        }
        let length = edit.word.utf16.count
        guard let target, edit.offset >= 0, edit.offset + length <= target.bytes.count else { return false }
        let original = target.bytes
        for i in 0..<length { target.bytes[edit.offset + i] = original[edit.offset + length - 1 - i] }
        guard let added = try? document.add(PdfStream(PdfDictionary(), data: ContentWriter.write(operations))) else { return false }
        page.dictionary["Contents"] = added
        return true
    }
}
