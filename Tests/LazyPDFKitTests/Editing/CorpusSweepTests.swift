import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/CorpusSweepTests.cs: the other changes on the first pages of every corpus
// file (LAZYPDF_CORPUS; without it the files of Tests/Fixtures): none may throw and the file must reopen without
// repairs. A paragraph set again with its own text is counted by whether its words read back the same.

final class CorpusSweepTests: XCTestCase {
    // Ten changes a page cost about a second a page, so a file gets its first few pages.
    private var pagesPerFile: Int { Int(ProcessInfo.processInfo.environment["LAZYPDF_CORPUS_PAGES"] ?? "") ?? 3 }

    private func words(_ document: PdfDocument, _ page: Int) -> [String] {
        TextPage.create(document, document.pages[page]).words.map { $0.text }.sorted()
    }

    // string.ReplaceLineEndings(" ")
    private func replaceLineEndings(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 10 && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = v == 13
            if v == 10 || v == 13 || v == 12 || v == 0x85 || v == 0x2028 || v == 0x2029 { result.append(" ") } else { result.append(scalar) }
        }
        return String(result)
    }

    func test_everyKindOfChangeLeavesAFileThatReopens() throws {
        var outcomes: [String: Int] = [:]
        func count(_ what: String, _ outcome: String) { outcomes["\(what): \(outcome)", default: 0] += 1 }
        var opened = 0
        for path in EditKit.corpusFiles() where FileManager.default.fileExists(atPath: path) {
            let session: PdfEditSession
            do {
                session = try PdfEditSession.open(path: path)
            } catch is PdfReadException {
                continue
            }
            opened += 1
            for p in 0..<min(session.document.pages.count, pagesPerFile) {
                try run("set again", p, session, count) { editor in
                    guard let block = try editor.objects.compactMap({ $0 as? TextObject }).first(where: { $0.lines.count > 1 && !$0.isTable }) else { return nil }
                    let before = words(session.document, p)
                    let result = try editor.replaceParagraph(block, replaceLineEndings(block.text))
                    if !result.done { return "refused: " + (result.problem ?? "") }
                    let after = words(try PdfDocument.open(session.current), p)
                    if before == after { return "ok" }
                    if !result.substitutions.isEmpty { return "ok, other font used" }
                    let lost = Set(before).subtracting(after).count, gained = Set(after).subtracting(before).count
                    return "words changed (lost \(min(lost, 3)), gained \(min(gained, 3)))"
                }
                try run("bigger", p, session, count) { editor in
                    try editor.text.lines.isEmpty ? nil : done(try editor.setTextStyle([try editor.text.lines[0].range], TextStyleChange(size: 14, color: RgbColor(200, 0, 0))))
                }
                try run("align", p, session, count) { editor in
                    guard let block = try editor.objects.compactMap({ $0 as? TextObject }).first(where: { $0.lines.count > 1 }) else { return nil }
                    return done(try editor.setAlignment(block, .right))
                }
                try run("spacing", p, session, count) { editor in
                    guard let block = try editor.objects.compactMap({ $0 as? TextObject }).first(where: { $0.lines.count > 1 && $0.lineSpacing > 0 }) else { return nil }
                    return done(try editor.setLineSpacing(block, block.lineSpacing * 1.5))
                }
                try run("delete word", p, session, count) { editor in
                    try editor.text.words.isEmpty ? nil : done(try editor.deleteText(try editor.text.words[0].range))
                }
                try run("text box", p, session, count) { editor in
                    done(try editor.addTextBox(PdfRect(50, 50, 250, 120), "Added text, wrapped in its box."))
                }
                try run("delete objects", p, session, count) { editor in
                    try editor.objects.isEmpty ? nil : done(try editor.delete(Array(try editor.objects.prefix(3))))
                }
                try run("rotate", p, session, count) { editor in
                    try editor.objects.isEmpty ? nil : done(try editor.rotate(Array(try editor.objects.prefix(3)), 25))
                }
                try run("opacity", p, session, count) { editor in
                    let paths = Array(try editor.objects.compactMap { $0 as? PathObject }.prefix(2))
                    return paths.isEmpty ? nil : done(try editor.setOpacity(paths, 0.5))
                }
                try run("order", p, session, count) { editor in
                    guard let o = try editor.objects.first(where: { $0 is ImageObject || $0 is PathObject }) else { return nil }
                    return done(try editor.order(o, .front))
                }
            }
        }
        for (what, n) in outcomes.sorted(by: { $0.key < $1.key }) { print("  \(n)  \(what)") }
        XCTAssertGreaterThan(opened, 0)
        XCTAssertFalse(outcomes.keys.contains { $0.contains("exception") || $0.contains("does not reopen") })
    }

    private func done(_ result: TextEditResult) -> String { result.done ? "ok" : "refused: " + (result.problem ?? "") }

    private func done(_ result: ObjectEditResult) -> String {
        if result.done { return result.skipped.isEmpty ? "ok" : "ok, some skipped" }
        var seen: [String] = []
        for each in result.skipped.map({ $0.reason }) where !seen.contains(each) { seen.append(each) }
        return "refused: " + seen.joined(separator: "; ")
    }

    // One change on one page; the outcome is counted, the page checked and the change undone.
    private func run(_ what: String, _ page: Int, _ session: PdfEditSession, _ count: (String, String) -> Void,
                     _ change: (PageEditor) throws -> String?) throws {
        var outcome: String?
        let repairs = session.document.repairs.count
        do {
            outcome = try change(try PageEditor(session, page, EditArialSource()))
            if let found = outcome, found.hasPrefix("ok") {
                let document = try PdfDocument.open(session.current)
                _ = TextPage.create(document, document.pages[page])
                if document.repairs.count > repairs { outcome = "does not reopen cleanly" }
            }
        } catch {
            outcome = "exception \(type(of: error))"
        }
        if let outcome { count(what, outcome) }
        while session.canUndo { _ = try session.undo() }
    }
}
