#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureTextTests.cs: the same cases. The enums have no
// GetValues, so the lists of verdicts, problems and kinds of change are written out below.

final class SignatureTextTests: XCTestCase {
    private let time = DateTimeOffset(2026, 3, 10, 9, 30, 0)

    private let verdicts: [SignatureVerdict] = [.valid, .validButUntrusted, .changedAfterSigning, .broken, .unknown]

    private let problems: [SignatureProblem] = [
        .unsupportedFormat, .badByteRange, .digestMismatch, .badSignature, .noCertificate, .untrustedSigner,
        .certificateNotValid, .certificateRevoked, .changedAfterSigning, .damagedStructure, .timestampInvalid, .weakDigest,
    ]

    private let kinds: [SignatureChangeKind] = [
        .formFill, .signature, .validationData, .comment, .metadata, .pageContent, .pageStructure, .form, .other, .unreadable,
    ]

    private func report(_ verdict: SignatureVerdict) -> SignatureReport {
        var report = SignatureReport()
        report.verdict = verdict
        report.signerName = "Ada Lovelace"
        report.signingTime = time
        return report
    }

    func test_eachVerdictHasOnePlainSentence() {
        let cases: [(SignatureVerdict, String)] = [
            (.valid, "Signed by Ada Lovelace on 10 Mar 2026. Not changed since."),
            (.validButUntrusted, "Signed by Ada Lovelace on 10 Mar 2026. The signer is not trusted."),
            (.changedAfterSigning, "Signed by Ada Lovelace on 10 Mar 2026. Changed since."),
            (.broken, "The signature by Ada Lovelace is not valid."),
            (.unknown, "This signature could not be checked."),
        ]
        for (verdict, sentence) in cases {
            XCTAssertEqual(report(verdict).sentence, sentence, "\(verdict)")
        }
    }

    func test_allowedChangesAndMissingFactsAreSaidPlainly() {
        var allowed = report(.valid)
        allowed.changes = SignatureChangeReport([SignatureChange(.formFill, 5, -1, "Name", true)], 1)
        XCTAssertEqual(allowed.sentence, "Signed by Ada Lovelace on 10 Mar 2026. Changed only as the signer allowed.")

        var nameless = SignatureReport()
        nameless.verdict = .valid
        XCTAssertEqual(nameless.sentence, "Signed by an unknown signer. Not changed since.")

        var stamp = SignatureReport()
        stamp.verdict = .valid
        stamp.kind = .documentTimestamp
        stamp.timestampTime = time
        XCTAssertEqual(stamp.sentence, "Time stamped on 10 Mar 2026. Not changed since.")
    }

    func test_aStatusLineIsSixWordsAtMost() {
        for verdict in verdicts {
            let line = SignatureText.status(verdict)
            let words = line.split(separator: " ", omittingEmptySubsequences: false).count
            XCTAssertTrue((1...6).contains(words), "\(verdict)")
            XCTAssertFalse(line.hasSuffix("."), "\(verdict)")
        }
        XCTAssertEqual(Set(verdicts.map { SignatureText.status($0) }).count, 5)
    }

    func test_everyProblemHasATitleAndSomethingToDo() {
        for problem in problems {
            let title = SignatureText.title(problem), advice = SignatureText.advice(problem)
            XCTAssertFalse(title.isEmpty, "\(problem)")
            XCTAssertFalse(advice.isEmpty, "\(problem)")
            XCTAssertFalse(title.hasSuffix("."), "\(problem)")
            XCTAssertTrue(advice.hasSuffix("."), "\(problem)")
        }
        XCTAssertEqual(Set(problems.map { SignatureText.title($0) }).count, problems.count)
    }

    func test_everyKindOfChangeIsDescribed() {
        for kind in kinds {
            XCTAssertFalse(SignatureText.describe(SignatureChange(kind, 1, 2, nil, false)).isEmpty, "\(kind)")
        }
        XCTAssertEqual(SignatureText.describe(SignatureChange(.pageContent, 1, 2, nil, false)), "Page content changed on page 3")
        XCTAssertEqual(SignatureText.describe(SignatureChange(.formFill, 1, -1, "Name", true)), "Form filled in field Name")
    }
}
#endif
