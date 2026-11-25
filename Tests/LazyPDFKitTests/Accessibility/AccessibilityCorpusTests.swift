import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Accessibility/AccessibilityCorpusTests.cs: checks every file in the list LAZYPDF_CORPUS
// names (one path per line), tags the untagged ones, reopens them and compares text and tags. Without the list it runs on
// the files of Tests/Fixtures/Documents and Tests/Fixtures/Pages instead of doing nothing. Only counts are printed. The C#
// also opens each tagged file in PdfPig; that check has no twin.

final class AccessibilityCorpusTests: XCTestCase {
    private func paths() -> [String] {
        if let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        var found: [String] = []
        for folder in ["Documents", "Pages"] {
            let directory = fixtures.appendingPathComponent(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            found += names.filter { $0.hasSuffix(".pdf") }.sorted().map { directory.appendingPathComponent($0).path }
        }
        return found
    }

    func test_everyFileIsCheckedAndEveryUntaggedFileCanBeTagged() throws {
        var files = 0, unreadable = 0, tagged = 0, untagged = 0, withTree = 0, done = 0, partly = 0, none = 0, pagesTagged = 0, pagesSkipped = 0
        var textChanged = 0, treeMismatch = 0, reopenFailed = 0, figures = 0, elements = 0, passed = 0, failed = 0, person = 0
        var problems: [String] = []
        let start = Date()
        for path in paths() {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let document: PdfDocument
            do {
                document = try PdfDocument.open([UInt8](data))
            } catch is PdfReadException {
                unreadable += 1
                continue
            }

            files += 1
            let report = try AccessibilityChecker.check(document)
            passed += report.passed
            failed += report.failed
            person += report.needsPerson
            if document.isTagged {
                tagged += 1
                _ = ReadingOrder.export(document)
                continue
            }

            untagged += 1
            do {
                let before = document.pages.map { TextPage.create(document, $0).text }
                let result = try AutoTagger.tag(document, AutoTagOptions("en-US"))
                if result.alreadyTagged {
                    withTree += 1
                    continue
                }
                pagesTagged += result.pages
                pagesSkipped += result.skippedPages
                figures += result.figures
                if result.pages == 0 {
                    none += 1
                } else if result.skippedPages > 0 {
                    partly += 1
                } else {
                    done += 1
                }

                let again = try PdfDocument.open(try document.saveRewrite())
                let tree = StructureTree.read(again)
                if result.pages > 0 { elements += tree?.elements.count ?? 0 }
                if !verify(again, tree, before, result.pages > 0) { textChanged += 1 }
                if result.pages > 0 && !treeMatchesContent(again, tree) { treeMismatch += 1 }
            } catch let e as PdfReadException {
                reopenFailed += 1
                if problems.count < 10 { problems.append("PdfReadException: \(e)") }
            } catch let e as InvalidOperationException {
                reopenFailed += 1
                if problems.count < 10 { problems.append("InvalidOperationException: \(e)") }
            }
        }

        print("files \(files), unreadable \(unreadable), already tagged \(tagged), untagged \(untagged) (with an unmarked tree \(withTree))")
        print("tagged whole \(done), in part \(partly), not at all \(none); pages tagged \(pagesTagged), skipped \(pagesSkipped), elements \(elements), figures \(figures)")
        print("checks passed \(passed), failed \(failed), needing a person \(person)")
        print("text changed \(textChanged), tree and content differ \(treeMismatch), reopen or write failed \(reopenFailed), \(Int(Date().timeIntervalSince(start))) s")
        for problem in problems { print(problem) }

        // The fixture files stand in for a corpus; a run that read none of them or tagged nothing has proved nothing.
        XCTAssertGreaterThan(files, 0)
        if ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"]?.isEmpty ?? true { XCTAssertGreaterThan(pagesTagged, 0) }
        XCTAssertEqual(textChanged, 0)
        XCTAssertEqual(treeMismatch, 0)
        XCTAssertEqual(reopenFailed, 0)
    }

    private func verify(_ document: PdfDocument, _ tree: StructureTree?, _ before: [String], _ tagged: Bool) -> Bool {
        if document.pages.count != before.count { return false }
        for i in 0..<before.count where TextPage.create(document, document.pages[i]).text != before[i] { return false }
        return !tagged || (tree != nil && document.isTagged)
    }

    // Every sequence the content of a tagged page opens is in the tree, and the parent tree names the element that holds it.
    private func treeMatchesContent(_ document: PdfDocument, _ tree: StructureTree?) -> Bool {
        guard let tree else { return false }
        for page in document.pages {
            let inTree = tree.contents.filter { $0.pageIndex == page.index && $0.stream == nil }
            if inTree.isEmpty { continue }
            let inContent = AccessKit.sequences(document, page.index).filter { $0.mcid >= 0 }.map { $0.mcid }
            if inContent.sorted() != inTree.map({ $0.mcid }).sorted() { return false }
            guard let key = document.integer(page.dictionary, "StructParents") else { return false }
            for content in inTree {
                guard let owner = tree.elementFor(key, content.mcid), owner.kids.contains(where: { $0 === content }) else { return false }
            }
        }
        return true
    }
}
