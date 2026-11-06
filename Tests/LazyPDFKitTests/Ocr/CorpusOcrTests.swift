import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Ocr/CorpusOcrTests.cs: runs a fake recognizer over every page of the files in the list
// LAZYPDF_CORPUS names (one path per line) that triage takes for a picture or a drawing; without it, the files of
// Tests/Fixtures/Documents, so that the test is never empty. Only counts are printed. The PdfPig read at the end has no twin.

final class CorpusOcrTests: XCTestCase {
    // Two words in the top left corner whatever the size of the picture.
    private struct CornerRecognizer: TextRecognizer {
        func recognizeAsync(_ image: PdfRgbaImage, _ language: String) async throws -> [OcrWord] {
            let w = Double(image.width), h = Double(image.height)
            return [OcrKit.word("page", w * 0.1, h * 0.1, w * 0.3, h * 0.04), OcrKit.word("tail", w * 0.45, h * 0.1, w * 0.3, h * 0.04)]
        }
    }

    private static let maxPages = 40

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

    func test_pagesThatNeedOcrTakeTheLayerAndKeepTheFileReadable() async throws {
        var opened = 0, withWork = 0, pages = 0, pictures = 0, layers = 0, ownLayers = 0, locked = 0
        var kinds: [OcrPageKind: Int] = [:]
        var failures: [String] = []
        for path in files() where FileManager.default.fileExists(atPath: path) {
            opened += 1
            let session: PdfEditSession
            do {
                session = try PdfEditSession.open(path: path)
            } catch is PdfReadException {
                locked += 1
                continue
            }
            do {
                let document = session.document
                let inspected = Array(0..<min(document.pages.count, Self.maxPages))
                for kind in OcrTriage.classifyAll(document).prefix(Self.maxPages) { kinds[kind, default: 0] += 1 }
                let wanted = inspected.filter { OcrTriage.needsOcr(OcrTriage.classify(document, document.pages[$0]), false, false) }
                pictures += wanted.filter { OcrTriage.classify(document, document.pages[$0]) == .picture }.count
                if wanted.isEmpty { continue }

                withWork += 1
                let recognizer = CornerRecognizer()
                let result = try await PdfSearchable.runAsync(session, recognizer, FakeRenderer(document), OcrOptions(dpi: 72, pages: inspected))
                pages += result.added
                if result.added != wanted.count || result.words != 2 * wanted.count { failures.append("\(opened): \(result.added) of \(wanted.count)") }

                let reopened = try PdfDocument.open(session.current)
                let has = wanted.filter { PdfOcrLayer.has(reopened, reopened.pages[$0]) }.count
                layers += has
                if has != wanted.count { failures.append("\(opened): layer on \(has) of \(wanted.count) after reopen") }
                for i in wanted.prefix(3) {
                    let words = TextPage.create(reopened, reopened.pages[i]).words.map { $0.text }
                    if !words.contains("tail") { failures.append("\(opened): page \(i) text") }
                }

                let again = try await PdfSearchable.runAsync(session, recognizer, FakeRenderer(session.document), OcrOptions(dpi: 72, existing: .replace, pages: inspected))
                if again.added != wanted.count { failures.append("\(opened): replace \(again.added) of \(wanted.count)") }
                let twice = try PdfDocument.open(session.current)
                ownLayers += wanted.filter { OcrKit.layerStreams(twice, $0) == 1 }.count
                if wanted.contains(where: { OcrKit.layerStreams(twice, $0) != 1 }) { failures.append("\(opened): layers after replace") }
            } catch is PdfReadException {
                locked += 1
            }
        }
        print("\(opened) files, \(locked) unreadable or locked, \(withWork) with pages for OCR (\(pages) pages, \(pictures) pictures), "
              + "\(layers) layers after reopen, \(ownLayers) single layers after replace, \(failures.count) failures")
        print(kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        XCTAssertGreaterThan(opened, 0)
        XCTAssertEqual(failures, [])
    }
}
