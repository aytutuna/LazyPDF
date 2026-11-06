#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureCoverageTests.cs: the same cases. Streams that are only
// plumbing, the trailer, and the walk over the whole file: none of them may hide a use of an object.

final class SignatureCoverageTests: XCTestCase {
    private let pki = Pki.instance

    private func check(_ file: [UInt8]) throws -> SignatureReport { try SignatureRawKit.check(file) }

    private func assertChanged(_ file: [UInt8], _ kind: SignatureChangeKind? = nil, line: UInt = #line) throws {
        let report = try check(file)
        XCTAssertEqual(report.verdict, .changedAfterSigning, line: line)
        if let kind { XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == kind }, line: line) }
    }

    private func signedAt(_ pdf: TestPdf, _ level: CertificationLevel) throws -> [UInt8] {
        try PdfSigner.sign(pdf.finish(), SignatureObjects.leafRequest { $0.certify = level })
    }

    private func be(_ value: Int) -> String {
        Latin1.string((0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) })
    }

    // A cross-reference stream whose four free rows spell a page's content, as number 99 that the signed page names and nothing defines.
    private func freeRowsSpellContent(_ signed: [UInt8]) throws -> [UInt8] {
        let document = try PdfDocument.open(signed)
        let words = ["BT /F1 18 Tf", "40 300 Td", "(pay 1,000,000)", "Tj ET %"]
        var rows = words.map { "\u{0}" + $0.padding(toLength: 16, withPad: " ", startingAt: 0) }.joined()
        let at = signed.count + 1
        rows += "\u{1}" + be(at) + be(0)
        let body = "<</Type /XRef /Size 104 /W [1 8 8] /Index [100 4 99 1] \(SignatureRawKit.kept(document)) /Prev \(document.startXref) /Length \(rows.unicodeScalars.count)>>\nstream\n\(rows)\nendstream"
        let text = "\n99 0 obj\n\(body)\nendobj\nstartxref\n\(at)\n%%EOF\n"
        return signed + TestPdf.latin(text)
    }

    func test_aCrossReferenceStreamOnANumberTheSignedPageNamesIsJudgedAsTheContentItBecomes() throws {
        for level in [CertificationLevel.noChanges, .annotate] {
            let signed = try signedAt(SignatureSharedRoleTests.doc(page: "/Contents [4 0 R 99 0 R]"), level)
            XCTAssertEqual(try check(signed).verdict, .valid)

            let attacked = try freeRowsSpellContent(signed)

            XCTAssertTrue(try SignatureRawKit.showsEvil(attacked), "\(level)")
            try assertChanged(attacked, .pageContent)
        }
    }

    func test_anObjectStreamAndCrossReferenceStreamNothingNamesAreNotChangesOfTheirOwn() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)
        let member = "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (200) /Rect [20 20 120 40]>>"

        let filled = try SignatureRawKit.withObjectStream(signed, "6 0 " + member, 1, 4, 6, 0)

        let report = try check(filled)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertTrue(report.changes.changes.contains { $0.kind == .formFill && $0.object == 6 })
        XCTAssertFalse(report.changes.changes.contains { $0.object == 40 || $0.object == 41 })
    }

    func test_anObjectStreamAPageNamesIsJudgedByThatUse() throws {
        let signed = try signedAt(SignatureSharedRoleTests.doc(page: "/Contents [4 0 R 40 0 R]"), .annotate)

        let attacked = try SignatureRawKit.withObjectStream(signed, "55 0 (note)", 1, 5, 55, 0)

        try assertChanged(attacked)
    }

    func test_informationAddedToTheTrailerWithoutAnObjectOfItsOwnIsNotAccepted() throws {
        let cases: [(String, CertificationLevel)] = [
            ("/Info <</Title (pay 1,000,000) /Author (Mallory)>>", .none),
            ("/Info <</Title (pay 1,000,000) /Author (Mallory)>>", .formFill),
            ("/Info 5 0 R", .none),
            ("/Info 5 0 R", .formFill),
        ]
        for (info, level) in cases {
            let signed = try signedAt(SignatureSharedRoleTests.doc(), level)

            let attacked = try SignatureRawKit.append(signed, " " + info, nil, [])

            XCTAssertFalse(try SignatureRawKit.passesGate(attacked), "\(info) \(level)")
            try assertChanged(attacked, .unreadable)
        }
    }

    func test_informationAddedAsAnObjectIsJudgedAsMetadata() throws {
        let cases: [(CertificationLevel, String, Bool)] = [
            (.none, "/Title (Quarterly)", false),
            (.noChanges, "/Title (Quarterly)", false),
            (.formFill, "/Title (Quarterly)", true),
            (.none, "/Producer (Writer) /ModDate (D:20261104110306Z)", true),
            (.noChanges, "/Producer (Writer) /ModDate (D:20261104110306Z)", true),
        ]
        for (level, keys, allowed) in cases {
            let signed = try signedAt(SignatureSharedRoleTests.doc(), level)

            let attacked = try SignatureRawKit.append(signed, " /Info 30 0 R", nil, [(30, "<<\(keys)>>")])

            let report = try check(attacked)
            XCTAssertEqual(report.verdict, allowed ? .valid : .changedAfterSigning, "\(level) \(keys)")
            XCTAssertTrue(report.changes.changes.contains { $0.kind == .metadata && $0.object == 30 && $0.allowed == allowed }, "\(level) \(keys)")
        }
    }

    func test_informationWhoseDatesMoveAgainInALaterUpdateIsStillJudged() throws {
        let signed = try signedAt(SignatureSharedRoleTests.doc(), .none)
        let first = try SignatureRawKit.append(signed, " /Info 30 0 R", nil, [(30, "<</ModDate (D:20261104110306Z)>>")])

        let second = try SignatureRawKit.append(first, "", nil, [(30, "<</Title (pay 1,000,000)>>")])

        XCTAssertEqual(try check(first).verdict, .valid)
        try assertChanged(second, .metadata)
    }

    func test_aSizeThatIsNotTheFirstNumberInNoUseIsNotAccepted() throws {
        for by in [-1, 1, 8_000_000] {
            let signed = try signedAt(SignatureSharedRoleTests.doc(), .annotate)

            let attacked = try SignatureRawKit.append(signed, "", PdfDocument.open(signed).nextObjectNumber + by, [])

            try assertChanged(attacked, .unreadable)
            XCTAssertEqual(try check(SignatureRawKit.append(signed, "", nil, [])).verdict, .valid, "\(by)")
        }
    }

    func test_aTrailerKeyAWriterLeftInTheSignedRevisionDoesNotFailTheUpdatesAfterIt() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
        pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>")
        let source = pdf.finish("/Root 1 0 R /DocChecksum /ABCDEF")
        let signed = try PdfSigner.sign(source, SignatureObjects.leafRequest { $0.certify = .formFill })
        XCTAssertEqual(try check(signed).verdict, .valid)

        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Amount", "200") }
        let second = try SignatureObjects.second(filled, fieldName: "Second")

        for report in try SignatureKit.verify(filled) { XCTAssertEqual(report.verdict, .valid) }
        for report in try SignatureKit.verify(second) { XCTAssertEqual(report.verdict, .valid) }
    }

    func test_aSignedObjectAConformingWriterMadeCanBeReplaced() throws {
        for oddity in ["length", "escape"] {
            let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]")
            let tip = oddity == "escape" ? "/TU (Am\\qount)" : ""
            pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) \(tip) /V (100) /Rect [20 20 120 40] /AP <</N 8 0 R>>>>")
            let length = oddity == "length" ? " /Length 9 0 R" : ""
            pdf.stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 100 20]" + length, "0 g", length: oddity == "length" ? -1 : nil)
            if oddity == "length" { pdf.obj(9, "3") }
            let signed = try SignatureSharedRoleTests.sign(pdf, .formFill)
            XCTAssertEqual(try check(signed).verdict, .valid, oddity)
            let now = oddity == "escape" ? "/TU (Amqount)" : ""

            let filled = try SignatureTestHelpers.appendRaw(signed, [
                (6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) \(now) /V (200) /Rect [20 20 120 40] /AP <</N 8 0 R>>>>"),
                (8, SignatureRawKit.streamBody("0 g 1 g", "/Type /XObject /Subtype /Form /BBox [0 0 100 20]")),
            ])

            let report = try check(filled)
            XCTAssertEqual(report.verdict, .valid, oddity)
            XCTAssertTrue(report.changes.changes.contains { $0.kind == .formFill && $0.object == 6 }, oddity)
        }
    }

    // 2700 pages that share a long chain of resources: every page walks the chain again under its own page number.
    private func sharedChain(_ pages: Int, _ chain: Int) -> TestPdf {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R /DSS <</Certs [4 0 R]>>>>")
        let kids = (0..<pages).map { "\(100 + $0) 0 R" }.joined(separator: " ")
        pdf.obj(2, "<</Type /Pages /Kids [\(kids)] /Count \(pages) /MediaBox [0 0 300 400]>>")
        pdf.stream(4, "", "BT ET")
        for i in 0..<pages { pdf.obj(100 + i, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources 3000 0 R>>") }
        for i in 0..<chain { pdf.obj(3000 + i, i + 1 < chain ? "<</Next \(3001 + i) 0 R>>" : "<<>>") }
        return pdf
    }

    func test_aWalkThatACapEndedEarlyIsNotTakenForComplete() throws {
        let signed = try signedAt(sharedChain(2700, 2000), .noChanges)
        XCTAssertEqual(try check(signed).verdict, .valid)

        let attacked = try SignatureTestHelpers.appendRaw(signed, [(4, SignatureRawKit.streamBody(SignatureRawKit.evil))])

        XCTAssertFalse(Jobs(try PdfDocument.open(signed)).complete)
        XCTAssertTrue(try SignatureRawKit.showsEvil(attacked))
        try assertChanged(attacked, .unreadable)
    }

    func test_aWalkOverAFileOfOrdinarySizeIsComplete() throws {
        let signed = try signedAt(sharedChain(40, 50), .noChanges)

        XCTAssertTrue(Jobs(try PdfDocument.open(signed)).complete)
    }

    func test_fieldsNestedDeeperThanTheWalkGoesMakeTheFileUnreadableNotUnnamed() throws {
        let pdf = SignatureSharedRoleTests.doc(catalog: "/AcroForm <</Fields [10 0 R]>>")
        for i in 0..<40 { pdf.obj(10 + i, i < 39 ? "<</FT /Tx /T (n\(i)) /Kids [\(11 + i) 0 R]>>" : "<</FT /Tx /T (leaf) /V (1)>>") }
        let signed = try signedAt(pdf, .formFill)

        XCTAssertFalse(Jobs(try PdfDocument.open(signed)).complete)
        try assertChanged(SignatureTestHelpers.appendRaw(signed, [(49, "<</FT /Tx /T (leaf) /V (2)>>")]), .unreadable)
    }
}
#endif
