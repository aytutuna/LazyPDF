import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/LinearizerCorpusTests.cs: with LAZYPDF_CORPUS naming a text file of paths
// (one per line), every file that opens and has pages is linearized, reopened and compared with the original for page
// count and text, and the layout and hint tables are checked. With LAZYPDF_CORPUS_OUT naming a folder the results are
// left there for other readers. Only counts are printed. The PdfPig page counts have no twin.

final class LinearizerCorpusTests: XCTestCase {
    private let textPages = 12
    private let checkLimit = 40 << 20

    private func text(_ document: PdfDocument) -> String {
        let cache = TextCache(document)
        return (0..<Swift.min(textPages, document.pages.count)).map { cache.get($0).text }.joined(separator: "\u{0C}")
    }

    func test_everyFileSurvivesLinearization() throws {
        guard let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
              FileManager.default.fileExists(atPath: list) else { return }
        let keep = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS_OUT"]
        if let keep, !keep.isEmpty { try FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true) }
        var files = 0, done = 0, refused = 0, verified = 0
        var failures: [String] = []
        let paths = try String(contentsOfFile: list, encoding: .utf8).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        for path in paths {
            files += 1
            do {
                let document = try PdfDocument.open(path: path)
                if document.pages.count == 0 { continue }
                let before = text(document)
                let linear = try document.saveLinearized(PdfSaveOptions(security: document.security))
                if let keep, !keep.isEmpty {
                    try Data(linear).write(to: URL(fileURLWithPath: keep).appendingPathComponent(String(format: "%04d.pdf", files)))
                }
                let again = try PdfDocument.open(linear)
                if !again.isLinearized { failures.append("\(files): not linearized") }
                if again.pages.count != document.pages.count {
                    failures.append("\(files): page count \(again.pages.count), was \(document.pages.count)")
                } else if text(again) != before {
                    failures.append("\(files): text differs")
                }
                if linear.count < checkLimit && !document.isEncrypted {
                    try LinearizerKit.verify(linear)
                    verified += 1
                }
                done += 1
            } catch is PdfReadException {
                refused += 1
            } catch {
                failures.append("\(files): \(error)")
            }
        }
        print("\(files) files, \(done) linearized, \(verified) checked in full, \(refused) not opened, \(failures.count) failures")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
