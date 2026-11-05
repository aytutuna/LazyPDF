import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Stamps/CorpusStampTests.cs: stamps every file in the list LAZYPDF_CORPUS names (one path
// per line), saves, reopens, removes the stamps again; without it, the files of Tests/Fixtures/Documents, of which the two
// owner-only ones open without a password and must be stamped. Only counts are printed. The PdfPig read of the saved file has no twin. The watermark text is the letters of
// the synthetic font.

final class CorpusStampTests: XCTestCase {
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

    private func layerCount(_ document: PdfDocument) -> Int {
        document.array(document.dict(document.catalog, "OCProperties"), "OCGs")?.items.count ?? 0
    }

    func test_everyFileTakesAllStampsAndLosesThemAgain() throws {
        var count = 0, stamped = 0, pages = 0, skipped = 0
        var failures: [String] = []
        let fonts = try ArialSource()
        for path in files() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            count += 1
            do {
                let document = try PdfDocument.open(path: path)
                if document.isSigned || document.pages.count == 0 || document.pages.count > 400 {
                    skipped += 1
                    continue
                }
                let layers = layerCount(document)
                let stamper = PdfStamper(document, fonts)
                let jpeg = try XCTUnwrap(try PdfImageWriter.addJpeg(document, StampKit.jpeg))
                try stamper.addBackground(BackgroundSpec(color: .gray(0.95), image: jpeg, opacity: 0.2))
                try stamper.addWatermark(WatermarkSpec(text: "AB İğı", rotation: 45, layerName: "Watermark"))
                try stamper.addWatermark(WatermarkSpec(image: jpeg, behind: true, pages: [0]))
                try stamper.addHeaderFooter(HeaderFooterSpec(
                    header: HeaderFooterBand("{file}", "", "{date}"),
                    footer: HeaderFooterBand("", "Page {page} of {pages}", "{bates}"),
                    date: DateTimeOffset(2026, 1, 2, 0, 0, 0),
                    fileName: "x.pdf",
                    bates: BatesSpec(prefix: "B", digits: 6, start: 1)))
                let runs = stamper.list().count
                let bytes = try document.saveRewrite()

                let reopened = try PdfDocument.open(bytes)
                let again = PdfStamper(reopened)
                if again.list().count != runs || reopened.pages.count != document.pages.count { failures.append("\(count): listing after reopen") }
                let viaUpdate = try PdfDocument.open(try document.saveIncremental())
                if PdfStamper(viaUpdate).list().count != runs { failures.append("\(count): listing after update") }

                again.removeAll()
                let last = try PdfDocument.open(try reopened.saveRewrite())
                if !PdfStamper(last).list().isEmpty || layerCount(last) != layers { failures.append("\(count): removal") }
                stamped += 1
                pages += document.pages.count
            } catch is PdfReadException {
                skipped += 1
            }
        }
        print("\(count) files, \(stamped) stamped (\(pages) pages), \(skipped) skipped, \(failures.count) failures")
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        if (ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"] ?? "").isEmpty { XCTAssertGreaterThanOrEqual(stamped, 2) }
    }
}
