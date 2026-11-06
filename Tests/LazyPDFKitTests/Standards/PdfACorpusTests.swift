import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfACorpusTests.cs: validates every file in the list LAZYPDF_CORPUS names (one
// path per line), converts each to PDF/A-2b and validates the result. Without the list it takes the files of
// Tests/Fixtures/Documents, where the C# does nothing, as the corpus tests of the other layers do. Only counts are printed.

final class PdfACorpusTests: XCTestCase {
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

    private func claimedLevel(_ document: PdfDocument) -> PdfALevel? {
        switch (document.pdfAPart, document.pdfAConformance) {
        case (1, _): return .a1b
        case (2, "U"): return .a2u
        case (2, _): return .a2b
        case (3, "U"): return .a3u
        case (3, _): return .a3b
        case (4, _): return .a4
        default: return nil
        }
    }

    func test_everyFileIsCheckedConvertedAndCheckedAgain() throws {
        var count = 0, clean = 0, converted = 0, refused = 0, failed = 0, claiming = 0, claimingClean = 0
        var before: [String: Int] = [:]
        var after: [String: Int] = [:]
        var claimed: [String: Int] = [:]
        var left: [String: Int] = [:]
        var refusals: [String: Int] = [:]
        var crashes: [String] = []
        let date = DateTimeOffset(2026, 1, 1, 0, 0, 0)
        let converter = PdfAConverter(SystemFonts())
        for path in files() {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let bytes = [UInt8](data)
            do {
                let document = try PdfDocument.open(bytes)
                count += 1
                if let own = claimedLevel(document) {
                    claiming += 1
                    let claim = PdfAValidator.validate(document, own)
                    if claim.isValid { claimingClean += 1 }
                    for clause in Set(claim.issues.map { "\(own.name()) \($0.clause)" }) { claimed[clause, default: 0] += 1 }
                }
                let report = PdfAValidator.validate(document, .a2b)
                if report.isValid { clean += 1 }
                for clause in Set(report.issues.map { $0.clause }) { before[clause, default: 0] += 1 }

                let result = try converter.convert(bytes, .a2b, date)
                guard let output = result.bytes else {
                    refused += 1
                    refusals[result.refusal ?? "", default: 0] += 1
                    continue
                }
                let remaining = PdfAValidator.validate(try PdfDocument.open(output), .a2b)
                if remaining.isValid { converted += 1 } else { failed += 1 }
                for clause in Set(remaining.issues.map { $0.clause }) { after[clause, default: 0] += 1 }
                for message in Set(remaining.issues.map { $0.clause + " " + $0.message }) { left[message, default: 0] += 1 }
            } catch is PdfReadException {
            } catch {
                crashes.append("\(error)")
            }
        }
        print("\(count) files: \(clean) already clean for PDF/A-2b, \(converted) converted clean, \(failed) converted with rules left, \(refused) refused")
        print("\(claiming) files claim a PDF/A level, \(claimingClean) of them pass it; clauses broken by those that claim: " + claimed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        print("files breaking each clause before: " + before.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        print("files breaking each clause after: " + after.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        print("what is left: " + left.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        print("refusals: " + refusals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        for level in [PdfALevel.a1b, PdfALevel.a4] { print(summary(level, &crashes)) }
        XCTAssertTrue(crashes.isEmpty, crashes.prefix(10).joined(separator: "\n"))
    }

    private func summary(_ level: PdfALevel, _ crashes: inout [String]) -> String {
        var clean = 0, left = 0, refused = 0
        let converter = PdfAConverter(SystemFonts())
        let date = DateTimeOffset(2026, 1, 1, 0, 0, 0)
        for path in files() {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            do {
                let result = try converter.convert([UInt8](data), level, date)
                if result.bytes == nil { refused += 1 } else if result.remaining.isEmpty { clean += 1 } else { left += 1 }
            } catch is PdfReadException {
            } catch {
                crashes.append("\(error)")
            }
        }
        return "\(level.name()): \(clean) converted clean, \(left) with rules left, \(refused) refused"
    }
}
