import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Export/CorpusExportTests.cs: runs every writer on every file in the list
// LAZYPDF_CORPUS names (one path per line) and parses the XML parts back. Without it, the PDFs of Tests/Fixtures stand in,
// and some of them must export. Only counts are printed.

final class CorpusExportTests: XCTestCase {
    private static let maxPages = 300

    private func files() -> (paths: [String], ours: Bool) {
        if let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            return (text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, false)
        }
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        var paths: [String] = []
        for folder in ["Documents", "Documents/annotations", "Pages"] {
            let directory = fixtures.appendingPathComponent(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            paths += names.filter { $0.hasSuffix(".pdf") }.sorted().map { directory.appendingPathComponent($0).path }
        }
        return (paths, true)
    }

    private func parseXml(_ package: [UInt8]) throws -> Bool {
        for entry in try ExportZipReader.read(package) where entry.name.hasSuffix(".xml") || entry.name.hasSuffix(".rels") {
            if XmlDocument.parse(entry.data) == nil { return false }
        }
        return true
    }

    func test_everyFormatOnEveryFileThrowsNothingButPdfReadException() throws {
        var count = 0, exported = 0, unreadable = 0, truncated = 0, pages = 0, tables = 0, headings = 0, listItems = 0, pictures = 0, extracted = 0
        var failures: [String] = []
        let (paths, ours) = files()
        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            count += 1
            do {
                let document = try PdfDocument.open(path: path)
                let chosen = Array(0..<min(document.pages.count, Self.maxPages))
                if document.pages.count > Self.maxPages { truncated += 1 }

                let model = try ExportLayout.analyze(document, chosen)
                pages += model.pages.count
                let blocks = model.pages.flatMap { $0.blocks }
                tables += blocks.filter { $0 is ExportTable }.count
                headings += blocks.compactMap { $0 as? ExportParagraph }.filter { $0.heading > 0 }.count
                listItems += blocks.compactMap { $0 as? ExportParagraph }.filter { $0.item != nil }.count
                pictures += model.pages.reduce(0) { $0 + $1.pictures.count }

                let docx = try DocxWriter.make(model)
                let xlsx = try XlsxWriter.make(model)
                let pptx = try PptxWriter.make(model)
                for package in [docx, xlsx, pptx] {
                    if try !parseXml(package) { failures.append("\(count): an XML part is not well-formed") }
                }
                _ = try HtmlWriter.reflowed(model)
                _ = try HtmlWriter.fixed(model)
                _ = try RtfWriter.make(model)
                _ = try MarkdownWriter.make(model)
                _ = try PlainTextWriter.make(model)
                extracted += try ImageExtractor.extract(document, chosen).count
                exported += 1
            } catch is PdfReadException {
                unreadable += 1
            } catch {
                failures.append("\(count): \(type(of: error)) \(error)")
            }
        }
        print("files \(count), exported \(exported), unreadable \(unreadable), over \(Self.maxPages) pages \(truncated); pages \(pages), tables \(tables), headings \(headings), list items \(listItems), pictures \(pictures), extracted \(extracted)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        if ours { XCTAssertGreaterThan(exported, 0, "no fixture file exported") }
    }
}
