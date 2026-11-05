import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Forms/FormCorpusTests.cs: reads the form of every file in the list LAZYPDF_CORPUS names
// (one path per line), exports it, fills and resets a copy, flattens another and looks for blanks on the first page;
// without it, the files of Tests/Fixtures/Documents and the standard test form, which is the one with fields. Only counts are
// printed.

final class FormCorpusTests: XCTestCase {
    private var list: String? {
        guard let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty else { return nil }
        return list
    }

    private func files() -> [[UInt8]] {
        let paths: [String]
        if let list, let text = try? String(contentsOfFile: list, encoding: .utf8) {
            paths = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            let folder = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures").appendingPathComponent("Documents")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            paths = names.filter { $0.hasSuffix(".pdf") }.sorted().map { folder.appendingPathComponent($0).path }
        }
        var all = paths.compactMap { FileManager.default.contents(atPath: $0).map { [UInt8]($0) } }
        if list == nil { all.append(FormFixtures.standard()) }
        return all
    }

    func test_everyFormReadsFillsExportsAndFlattens() throws {
        var count = 0, forms = 0, fields = 0, orphans = 0, xfa = 0, dynamic = 0, scripts = 0, notRun = 0
        var filled = 0, refused = 0, flattened = 0, burned = 0, detected = 0, detectedFiles = 0
        var problems: [String] = []
        for bytes in files() {
            let document: PdfDocument
            do {
                document = try PdfDocument.open(bytes)
            } catch is PdfReadException {
                continue
            }
            count += 1
            do {
                if document.pages.count > 0 {
                    let found = FieldDetector.detect(document, 0)
                    detected += found.count
                    if !found.isEmpty { detectedFiles += 1 }
                }
                let form = PdfForm.read(document)
                if form.xfa != .none { xfa += 1 }
                if form.xfa == .dynamic { dynamic += 1 }
                if form.fields.isEmpty { continue }
                forms += 1
                fields += form.fields.count
                orphans += form.orphans.count
                let all = form.scripts
                scripts += all.count
                notRun += all.filter { !$0.ran }.count
                _ = try PdfFdf.read(try PdfFdf.write(form.exportFdf()))
                _ = try PdfXfdf.read(try PdfXfdf.write(form.exportFdf()))
                _ = form.exportCsv()
                if document.pages.count > 0 { _ = form.tabSequence(0) }

                let target = form.fields.first { $0.kind == .text && !$0.has(.readOnly) && !$0.widgets.isEmpty && $0.widgets[0].pageIndex >= 0 }
                if let target {
                    do {
                        try form.setValue(target.name, "Test 123")
                        try form.reset()
                        filled += 1
                        let reopened = try PdfDocument.open(try document.saveIncremental())
                        _ = PdfForm.read(reopened).fields.count
                    } catch is InvalidOperationException {
                        refused += 1
                    }
                }

                let again = try PdfDocument.open(bytes)
                let flat = PdfForm.read(again)
                burned += try flat.flatten()
                flattened += 1
                _ = try PdfDocument.open(try again.saveRewrite())
            } catch is PdfReadException {
            } catch {
                problems.append("\(error)")
            }
        }
        print("\(count) files, \(forms) with fields (\(fields) fields, \(orphans) orphans), \(xfa) XFA (\(dynamic) dynamic), \(scripts) scripts (\(notRun) not run)")
        print("\(filled) filled and reset, \(refused) refused for lack of a font, \(flattened) flattened (\(burned) widgets), \(detected) blanks proposed in \(detectedFiles) files")
        print("\(problems.count) problems")
        for problem in Set(problems).sorted().prefix(10) { print(problem) }
        XCTAssertTrue(problems.isEmpty, "\(problems)")
        if list == nil { XCTAssertGreaterThan(forms, 0) }
    }
}
