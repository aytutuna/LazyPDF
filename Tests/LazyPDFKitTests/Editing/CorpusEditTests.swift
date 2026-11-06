import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/CorpusEditTests.cs: on every page with text of the corpus (LAZYPDF_CORPUS
// names the list file; without it the files of Tests/Fixtures, so that the test is never empty), replace the first
// word of a line with another of the same length, commit, reopen, and check the new word is there and the other lines
// read as before. LAZYPDF_EDIT_OUT names a folder that gets the first few edited files, to be drawn and looked at. The
// C# also counts any exception that is not a PdfReadException as a failure; here such an error is counted the same way.

final class CorpusEditTests: XCTestCase {
    // The letters of the word in another order, so that every glyph is one the font has.
    private func shuffled(_ word: String) -> String {
        let scalars = Array(word.unicodeScalars)
        guard let first = scalars.first else { return word }
        let rotated = String(String.UnicodeScalarView(Array(scalars.dropFirst()) + [first]))
        return rotated != word ? rotated : String(String.UnicodeScalarView(scalars.reversed()))
    }

    private func lines(_ document: PdfDocument, _ page: Int) -> [String] {
        TextPage.create(document, document.pages[page]).lines.map { $0.text }
    }

    func test_firstWordOfALineIsReplacedByOneOfTheSameLength() throws {
        let files = EditKit.corpusFiles()
        var failures: [String: Int] = [:]
        var pages = 0, ok = 0, opened = 0, unopened = 0, saved = 0
        let clock = Date()
        for path in files where FileManager.default.fileExists(atPath: path) {
            let session: PdfEditSession
            do {
                session = try PdfEditSession.open(path: path)
            } catch is PdfReadException {
                unopened += 1
                continue
            }
            opened += 1
            for p in 0..<session.document.pages.count {
                let (outcome, attempted) = attempt(session, p)
                if !attempted { continue }
                pages += 1
                if outcome == "ok" {
                    ok += 1
                    if saved < 4 && p > 0, let folder = ProcessInfo.processInfo.environment["LAZYPDF_EDIT_OUT"] {
                        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                        try Data(session.current).write(to: URL(fileURLWithPath: folder).appendingPathComponent("corpus-\(saved)-page\(p).pdf"))
                        saved += 1
                    }
                } else {
                    failures[outcome, default: 0] += 1
                }
                while session.canUndo { _ = try session.undo() }
            }
        }
        print("files \(files.count), opened \(opened), not opened \(unopened), pages tried \(pages), replaced \(ok), rate \(pages == 0 ? 0 : 100.0 * Double(ok) / Double(pages))%, \(Date().timeIntervalSince(clock)) s")
        for (reason, n) in failures.sorted(by: { $0.key < $1.key }) { print("  \(n)  \(reason)") }
        XCTAssertGreaterThan(opened, 0)
        XCTAssertFalse(failures.keys.contains { $0.hasPrefix("exception") })
        XCTAssertTrue(pages == 0 || ok >= pages / 2)
    }

    private func attempt(_ session: PdfEditSession, _ page: Int) -> (outcome: String, attempted: Bool) {
        var attempted = false
        do {
            let editor = PageEditor(session, page, EditArialSource())
            let text = editor.text
            let word = text.words.first { w in
                w.text.utf16.count >= 3 && w.text.utf16.allSatisfy { $0.isLetter } && text.lines[w.line].range.start == w.range.start
            }
            guard let word else { return ("no word", false) }
            attempted = true
            let before = lines(session.document, page)
            let replacement = shuffled(word.text)
            let result = try editor.replaceText(word.range, replacement)
            if !result.done { return ("refused: " + (result.problem ?? ""), attempted) }
            let document = try PdfDocument.open(session.current)
            var after = lines(document, page)
            if try TextSearch.find(TextPage.create(document, document.pages[page]), replacement, TextSearchOptions(matchCase: true)).isEmpty {
                return ("new word not found" + detail(text.chars[word.range.start], result, before[word.line], after), attempted)
            }
            var rest = before
            rest.remove(at: word.line)
            for line in rest {
                guard let at = after.firstIndex(of: line) else { return ("another line changed", attempted) }
                after.remove(at: at)
            }
            return ("ok", attempted)
        } catch {
            return ("exception \(type(of: error))", attempted)
        }
    }

    // What kind of text it was, to sort the failures by.
    private func detail(_ first: TextChar, _ result: TextEditResult, _ line: String, _ after: [String]) -> String {
        let kind = first.font == nil ? "no font" : first.font?.isComposite == true ? "composite" : first.font?.isType3 == true ? "type3" : "simple"
        let substituted = result.substitutions.isEmpty ? "" : ", substituted"
        let form = first.form == nil ? "" : ", in form"
        let moved = after.contains(line) ? ", line unchanged" : ""
        return " [\(kind)\(substituted)\(form)\(moved)]"
    }
}
