import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Content/CorpusInterpreterTests.cs: runs every page of every file in the list
// LAZYPDF_CORPUS names (one path per line) through the interpreter; without it, the files of Tests/Fixtures/Documents
// that open without a password, so that the test is never empty. Only counts and times are printed. The C# also
// reports any exception that is not a PdfReadException; in Swift such a failure is a trap that ends the run.

final class CorpusInterpreterTests: XCTestCase {
    private final class Counter: ContentVisitor {
        var glyphs = 0
        var paths = 0
        var images = 0
        var forms = 0
        var unicode = 0

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            glyphs += 1
            if glyph.unicode != nil { unicode += 1 }
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) { paths += 1 }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) { images += 1 }

        override func beginForm(_ context: ContentContext, _ form: FormInfo) { forms += 1 }
    }

    private func files() -> [String] {
        if let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("Documents")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".pdf") }.sorted().map { folder.appendingPathComponent($0).path }
    }

    func test_everyPageRunsWithoutAnythingButPdfReadException() {
        var opened = 0, pages = 0, truncated = 0
        let counter = Counter()
        var slowest = 0.0
        let total = Date()
        for path in files() where FileManager.default.fileExists(atPath: path) {
            do {
                let document = try PdfDocument.open(path: path)
                opened += 1
                let interpreter = ContentInterpreter(document)
                let started = Date()
                for page in document.pages {
                    interpreter.run(page, counter)
                    pages += 1
                    if interpreter.isTruncated { truncated += 1 }
                }
                slowest = max(slowest, Date().timeIntervalSince(started))
            } catch is PdfReadException {
            } catch {
                XCTFail("\(path): \(error)")
            }
        }
        print("\(opened) files, \(pages) pages, \(counter.glyphs) glyphs (\(counter.unicode) with text), \(counter.paths) paths, \(counter.images) images, \(counter.forms) forms, \(truncated) truncated; slowest file \(slowest) s, total \(Date().timeIntervalSince(total)) s")
        XCTAssertGreaterThan(opened, 0)
        XCTAssertGreaterThan(pages, 0)
        XCTAssertLessThan(slowest, 120, "slowest file took \(slowest) s")
    }
}
