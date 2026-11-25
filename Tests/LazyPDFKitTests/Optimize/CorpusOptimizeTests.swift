import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Optimize/CorpusOptimizeTests.cs: optimises every file in the list LAZYPDF_CORPUS
// names (one path per line) on each preset and cleans it once, then reopens the result. Does nothing without the
// variable; only counts are printed. The PdfPig reads have no twin.

final class CorpusOptimizeTests: XCTestCase {
    private let maxPages = 300
    private let maxBytes = 60 << 20
    private let textPages = 12

    private func text(_ document: PdfDocument) -> String {
        let cache = TextCache(document)
        return (0..<Swift.min(textPages, document.pages.count)).map { cache.get($0).text }.joined(separator: "\u{0C}")
    }

    func test_everyFileShrinksOnEachPresetAndKeepsItsTextAndPages() throws {
        guard let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"], !list.isEmpty,
              FileManager.default.fileExists(atPath: list) else { return }
        let presets: [OptimizePreset] = [.small, .balanced, .highQuality]
        var plainTotal = 0
        var optimizedTotal = [Int](repeating: 0, count: presets.count)
        var sanitizedTotal = 0
        var files = 0, done = 0, skipped = 0, sanitized = 0, layerFiles = 0
        var failures: [String] = []
        let codec = OptimizeFakeCodec()
        let paths = try String(contentsOfFile: list, encoding: .utf8).components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        for path in paths where FileManager.default.fileExists(atPath: path) {
            files += 1
            do {
                let document = try PdfDocument.open(path: path)
                if document.isSigned || document.pages.count == 0 || document.pages.count > maxPages || document.length > maxBytes {
                    skipped += 1
                    continue
                }
                let before = text(document)
                let plain = try document.saveRewrite().count
                plainTotal += plain
                for (i, preset) in presets.enumerated() {
                    let result = try PdfOptimizer(document, codec).run(OptimizeOptions.for(preset))
                    optimizedTotal[i] += result.sizeAfter
                    if result.sizeAfter > plain { failures.append("\(files): \(preset) larger than a plain rewrite") }
                    let reopened = try PdfDocument.open(result.bytes)
                    if reopened.pages.count != document.pages.count {
                        failures.append("\(files): \(preset) page count")
                    } else if text(reopened) != before {
                        failures.append("\(files): \(preset) text")
                    }
                }
                let clean = try PdfSanitizer(document).run(SanitizeOptions())
                sanitizedTotal += clean.sizeAfter
                let cleaned = try PdfDocument.open(clean.bytes)
                if cleaned.pages.count != document.pages.count { failures.append("\(files): sanitized page count") }
                if clean.removed.contains(where: { $0.item == .hiddenLayers }) {
                    layerFiles += 1
                } else if text(cleaned) != before {
                    failures.append("\(files): sanitized text")
                }
                sanitized += 1
                done += 1
            } catch is PdfReadException {
                skipped += 1
            }
        }
        let savings = presets.enumerated().map { "\($1) \(String(format: "%.1f", 100.0 * Double(plainTotal - optimizedTotal[$0]) / Double(Swift.max(1, plainTotal))))%" }.joined(separator: ", ")
        print("\(files) files, \(done) optimised, \(skipped) skipped, \(sanitized) cleaned (\(layerFiles) with hidden layers), \(failures.count) failures")
        print("plain rewrites \(plainTotal) bytes; saved against them: \(savings); cleaned total \(sanitizedTotal) bytes")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
