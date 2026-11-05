import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Annotations/AnnotationCorpusTests.cs: reads the annotations of every file in the list
// LAZYPDF_CORPUS names (one path per line), moves them through FDF and XFDF, adds one of ours and flattens a copy.
// Without it, the files of Tests/Fixtures/Documents/annotations stand in, and the counts must show that annotations were
// read and changed. Only counts are printed.

final class AnnotationCorpusTests: XCTestCase {
    private func files() -> (paths: [String], ours: Bool) {
        if let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            return (text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, false)
        }
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent("Documents").appendingPathComponent("annotations")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return (names.filter { $0.hasSuffix(".pdf") }.sorted().map { folder.appendingPathComponent($0).path }, true)
    }

    func test_everyFileReadsExportsAndTakesANewAnnotation() throws {
        var count = 0, annotated = 0, annotations = 0, comments = 0, replies = 0, exported = 0, flattened = 0, imported = 0, changed = 0
        var problems: [String] = []
        let (paths, ours) = files()
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let document: PdfDocument
            do {
                document = try PdfDocument.open(path: path)
            } catch is PdfReadException {
                continue
            }
            count += 1
            do {
                let all = PdfAnnotations.readAll(document)
                annotations += all.count
                if !all.isEmpty { annotated += 1 }
                let thread = PdfComments.list(document)
                comments += thread.count
                replies += thread.reduce(0) { $0 + $1.replies.count }
                for order in [CommentOrder.page, .date, .author, .type] { _ = PdfComments.list(document, nil, order) }

                let fdf = try PdfFdf.export(document)
                exported += fdf.annotations.count
                let again = try PdfFdf.read(try PdfFdf.write(fdf))
                if again.annotations.count != fdf.annotations.count { problems.append("FDF lost annotations") }
                let xfdf = try PdfXfdf.read(try PdfXfdf.write(fdf))
                if xfdf.annotations.count != fdf.annotations.count { problems.append("XFDF lost annotations") }
                imported += try PdfFdf.import(try PdfDocument.open(TestPdf.simple(max(1, document.pages.count))), again).imported

                guard document.pages.count > 0 else { continue }
                let page = document.pages[0]
                let writer = PdfAnnotationWriter(document)
                let box = page.cropBox
                try writer.addTextMarkup(page, .highlight, [MarkupQuad.fromRect(PdfRect(box.left + 10, box.bottom + 10, box.left + 100, box.bottom + 24))])
                try writer.addFreeText(page, PdfRect(box.left + 10, box.bottom + 40, box.left + 150, box.bottom + 80), "Test")
                for found in all.filter({ $0.reference != nil && $0.type != .widget && $0.type != .popup }).prefix(8) {
                    do {
                        var moved = try writer.move(found, 5, 5)
                        moved = try writer.resize(moved, PdfRect(moved.rect.left, moved.rect.bottom, moved.rect.left + moved.rect.width + 10, moved.rect.bottom + moved.rect.height + 10))
                        try writer.setOpacity(try writer.setColor(moved, [0, 0.5, 1]), 0.8)
                        changed += 1
                    } catch is InvalidOperationException {
                        // Text no Standard 14 font can draw, and no font source given.
                    }
                }
                let edited = try PdfDocument.open(try document.saveIncremental())
                if PdfAnnotations.read(edited, edited.pages[0]).count != PdfAnnotations.read(document, page).count { problems.append("an annotation was lost in a save") }

                flattened += try PdfAnnotationFlattener.flattenAll(edited)
                _ = try PdfDocument.open(try edited.saveRewrite())
            } catch is PdfReadException {
            } catch {
                problems.append("\(error) in \(path)")
            }
        }
        print("\(count) files, \(annotated) with annotations (\(annotations) in all), \(comments) comments with \(replies) replies, "
            + "\(exported) exported to FDF, \(imported) imported again, \(changed) edited, \(flattened) flattened")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        if ours { XCTAssertTrue(annotated > 0 && comments > 0 && exported > 0 && changed > 0 && flattened > 0, "the fixture has annotations to read, change and flatten") }
    }
}
