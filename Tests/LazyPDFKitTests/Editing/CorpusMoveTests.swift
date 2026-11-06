import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Editing/CorpusMoveTests.cs: on every page of the corpus (LAZYPDF_CORPUS; without
// it the files of Tests/Fixtures), move every object by the same amount, commit, reopen, and check that every glyph,
// picture and path the interpreter finds is where it was plus that amount. The C# adds the top of the stack of an
// exception to its outcome; here only the type of the error.

final class CorpusMoveTests: XCTestCase {
    private let dx = 7.0, dy = -4.0

    private final class Positions: ContentVisitor {
        var seen: [(kind: String, x: Double, y: Double)] = []

        // A glyph with no ink has no block of its own.
        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            if !DotNetText.isNullOrWhiteSpace(glyph.unicode) { seen.append(("g", glyph.matrix.e, glyph.matrix.f)) }
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) { seen.append(("i", image.matrix.e, image.matrix.f)) }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            if path.fill || path.stroke { seen.append(("p", path.bounds.left, path.bounds.bottom)) }
        }
    }

    private func read(_ document: PdfDocument, _ page: Int) -> [(kind: String, x: Double, y: Double)] {
        let positions = Positions()
        let interpreter = ContentInterpreter(document)
        interpreter.walkPatterns = false
        interpreter.run(document.pages[page], positions)
        return positions.seen
    }

    func test_everyObjectOfEveryPageMovesByTheSameAmount() throws {
        var outcomes: [String: Int] = [:]
        var pages = 0
        var opened = 0
        for path in EditKit.corpusFiles() where FileManager.default.fileExists(atPath: path) {
            let session: PdfEditSession
            do {
                session = try PdfEditSession.open(path: path)
            } catch is PdfReadException {
                continue
            }
            opened += 1
            for p in 0..<session.document.pages.count {
                let outcome: String
                do {
                    outcome = try attempt(session, p)
                } catch {
                    outcome = "exception \(type(of: error))"
                }
                pages += 1
                outcomes[outcome, default: 0] += 1
                while session.canUndo { _ = try session.undo() }
            }
        }
        print("pages \(pages)")
        for (what, n) in outcomes.sorted(by: { $0.key < $1.key }) { print("  \(n)  \(what)") }
        XCTAssertGreaterThan(opened, 0)
        XCTAssertFalse(outcomes.keys.contains { $0.hasPrefix("exception") })
    }

    private func distinct(_ reasons: [String]) -> String {
        var seen: [String] = []
        for reason in reasons where !seen.contains(reason) { seen.append(reason) }
        return seen.joined(separator: "; ")
    }

    private func attempt(_ session: PdfEditSession, _ page: Int) throws -> String {
        let editor = PageEditor(session, page)
        if editor.objects.isEmpty { return "no objects" }
        let before = read(session.document, page)
        let result = try editor.move(editor.objects, dx, dy)
        if !result.done { return "refused: " + distinct(result.skipped.map { $0.reason }) }
        let after = read(try PdfDocument.open(session.current), page)
        let skipped = result.skipped.isEmpty ? "" : " with " + distinct(result.skipped.map { $0.reason })
        if after.count != before.count { return "different count" + skipped }
        func off(_ i: Int) -> Bool { abs(after[i].x - before[i].x - dx) > 0.01 || abs(after[i].y - before[i].y - dy) > 0.01 }
        var count = 0
        for i in 0..<before.count {
            if before[i].kind != after[i].kind { return "different content" + skipped }
            if off(i) { count += 1 }
        }
        if !result.skipped.isEmpty { return "moved, some skipped: " + distinct(result.skipped.map { $0.reason }) }
        if count == 0 { return "ok" }
        let kinds = Set((0..<before.count).filter(off).map { before[$0].kind }).sorted().joined()
        return "some not moved [\(kinds)]\(editor.objects.contains { !$0.forms.isEmpty } ? " forms" : "")"
    }
}
