#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureCorpusTests.cs: the same case. The list of files comes from
// the LAZYPDF_CORPUS environment variable, as in the C#; without it the case has nothing to read and passes at once,
// which the C# does too.

final class SignatureCorpusTests: XCTestCase {
    private func corpus() -> [String]? {
        guard let list = ProcessInfo.processInfo.environment["LAZYPDF_CORPUS"],
              let text = try? String(contentsOfFile: list, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init).filter { !$0.isEmpty }
    }

    func test_realFilesAreSignedAsAnUpdateAndReadBackWithoutAThrow() throws {
        guard let files = corpus() else { return }
        let pki = Pki.instance
        var signed = 0, skipped = 0, alreadySigned = 0, valid = 0
        for path in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? Int, size <= 40_000_000,
                  let data = FileManager.default.contents(atPath: path) else {
                skipped += 1
                continue
            }
            let file = [UInt8](data)
            do {
                let existing = try PdfSignatureVerifier.verify(file, pki.trusting)
                if !existing.isEmpty { alreadySigned += 1 }
                _ = PdfRevisions.list(file)
                let result = try PdfSigner.sign(file, SignatureKit.request(pki))
                let reports = try PdfSignatureVerifier.verify(result, pki.trusting)
                XCTAssertEqual(reports.count, existing.count + 1, path)
                XCTAssertEqual(reports.last?.verdict, .valid, path)
                signed += 1
                valid += reports.last?.verdict == .valid ? 1 : 0
            } catch is PdfReadException {
                skipped += 1
            }
        }
        print("signed \(signed), valid \(valid), already signed \(alreadySigned), skipped \(skipped)")
        XCTAssertEqual(signed, valid)
    }
}
#endif
