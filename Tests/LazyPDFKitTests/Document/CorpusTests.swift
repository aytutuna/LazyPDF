import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/CorpusTests.cs: opens every file in a list when LAZYPDF_CORPUS names
// a text file of paths (one per line); does nothing otherwise. Each file must open or fail with PdfReadException,
// and the same goes for reading its pages. Only counts and sizes are printed.

final class CorpusTests: XCTestCase {
    func test_everyFileOpensOrFailsCleanly() throws {
        guard let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
              FileManager.default.fileExists(atPath: list) else { return }

        var opened = 0, refused = 0, repaired = 0, pages = 0
        var bytes = 0
        let paths = try String(contentsOfFile: list, encoding: .utf8).components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            do {
                let document = try PdfDocument.open(path: path)
                opened += 1
                bytes += size
                if !document.repairs.isEmpty { repaired += 1 }
                pages += document.pages.count
                for page in document.pages.prefix(20) {
                    _ = page.mediaBox
                    _ = PageGeometry(page)
                    _ = page.contents()
                }
                _ = document.pdfAPart
                _ = document.isSigned
            } catch let failure as PdfReadException {
                refused += 1
                print("refused \(failure.problem), \(size) bytes")
            }
        }
        print("opened \(opened) (\(bytes / 1024) KB), repaired \(repaired), refused \(refused), \(pages) pages")
    }
}
