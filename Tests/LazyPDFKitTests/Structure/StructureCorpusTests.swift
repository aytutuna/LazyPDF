import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/StructureCorpusTests.cs: reads every structure of every file in the list
// LAZYPDF_CORPUS names (one path per line) and writes the outline, labels, metadata and layers back; without it, the
// files of Tests/Fixtures/Documents, so that the test is never empty. Only counts are printed.

final class StructureCorpusTests: XCTestCase {
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

    private func count(_ item: OutlineItem) -> Int {
        item.children.reduce(0) { $0 + 1 + count($1) }
    }

    private func titles(_ item: OutlineItem) -> [String] {
        item.children.flatMap { [$0.title] + titles($0) }
    }

    func test_everyStructureReadsAndTheOutlineSurvivesAWrite() throws {
        var count = 0, outlines = 0, items = 0, named = 0, labelled = 0, attachments = 0, layers = 0, links = 0, scripts = 0, titled = 0
        var problems: [String] = []
        for path in files() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let document: PdfDocument
            do {
                document = try PdfDocument.open(path: path)
            } catch is PdfReadException {
                continue
            }
            count += 1
            do {
                let facts = DocumentFacts.read(document)
                if facts.metadata.title != nil { titled += 1 }
                if facts.hasJavaScript { scripts += 1 }
                attachments += facts.attachmentCount
                layers += facts.layerCount
                named += PdfDestinations.named(document).count
                if !PdfPageLabels.read(document).isEmpty { labelled += 1 }
                _ = PdfPageLabels.labels(document)
                _ = ViewerSettings.read(document)
                _ = PdfActions.readDocument(document)
                _ = PdfPortfolio.read(document)
                for page in document.pages.prefix(30) { links += PdfLinks.read(document, page).count }
                for attachment in PdfAttachments.list(document).prefix(3) { _ = try PdfAttachments.extract(document, attachment) }

                let outline = Outline.read(document)
                let total = self.count(outline.root)
                items += total
                if total > 0 { outlines += 1 }
                let before = titles(outline.root)
                try outline.write(document)
                let again = Outline.read(try PdfDocument.open(try document.saveIncremental()))
                if before != titles(again.root) { problems.append("outline changed in a write (\(total) items)") }

                let set = PdfLayers.read(document)
                if let first = set.layers.first { PdfLayers.setVisible(document, first.reference, !first.isOn) }
                try DocumentMetadata.read(document).write(document)
                ViewerSettings.read(document).write(document)
                try PdfPageLabels.write(document, PdfPageLabels.read(document))
                _ = try PdfDocument.open(try document.saveIncremental())
            } catch is PdfReadException {
            } catch {
                problems.append("\(error) in \(path)")
            }
        }
        print("\(count) files, \(titled) titled, \(outlines) with bookmarks (\(items) items), \(named) named destinations, \(labelled) with labels, "
            + "\(attachments) attachments, \(layers) layers, \(links) links on first pages, \(scripts) with scripts")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }
}
