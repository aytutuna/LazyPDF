#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureRegeneratedTests.cs: the same cases.

final class SignatureRegeneratedTests: XCTestCase {
    // The annotation is written again under generation 1 and the page lists that one, so no reference to generation 0 is left.
    private func regenerate(_ signed: [UInt8], keepOldReference: Bool) throws -> [UInt8] {
        let document = try PdfDocument.open(signed)
        let page = document.pages[0]
        let stamp = try XCTUnwrap(PdfAnnotations.read(document, page).first { $0.type == .stamp }?.reference).number
        var holder = page.reference.number
        if let listed = page.dictionary["Annots"] as? PdfReference { holder = listed.number }

        let holderText = try XCTUnwrap(document.get(holder)).description
        let stampText = try XCTUnwrap(document.get(stamp)).description
        let moved = holderText.replacingOccurrences(of: "\\b\(stamp) 0 R", with: keepOldReference ? "\(stamp) 0 R \(stamp) 1 R" : "\(stamp) 1 R",
                                                    options: .regularExpression)
        var text = "\n"
        let stampAt = signed.count + text.unicodeScalars.count
        text += "\(stamp) 1 obj\n\(stampText)\nendobj\n"
        let holderAt = signed.count + text.unicodeScalars.count
        text += "\(holder) 0 obj\n\(moved)\nendobj\n"
        let xref = signed.count + text.unicodeScalars.count
        text += "xref\n"
        for (number, generation, at) in [(stamp, 1, stampAt), (holder, 0, holderAt)].sorted(by: { $0.0 < $1.0 }) {
            text += "\(number) 1\n" + String(format: "%010ld %05ld n \n", at, generation)
        }
        text += "trailer\n<</Size \(document.nextObjectNumber)\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(xref)\n%%EOF\n"
        return signed + TestPdf.latin(text)
    }

    private func signed() throws -> [UInt8] {
        let withStamp = try SignatureTestHelpers.edit(SignatureTestHelpers.formFile()) { d in
            _ = try PdfAnnotationWriter(d).addStamp(d.pages[0], PdfRect(30, 280, 270, 330), "VOID")
        }
        return try PdfSigner.sign(withStamp, SignatureObjects.leafRequest { $0.certify = .annotate })
    }

    func test_anAnnotationMovedToANewGenerationIsNotAllowedWhateverIsLeftOfTheOldReference() throws {
        let report = try SignatureKit.verify(regenerate(signed(), keepOldReference: false))[0]

        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .other })
    }

    func test_anAnnotationStillListedWithItsOldGenerationIsNotAllowed() throws {
        let report = try SignatureKit.verify(regenerate(signed(), keepOldReference: true))[0]

        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .other })
    }

    func test_aPageWhoseHolderAlreadyNamesTheNewGenerationIsComparedWithTheSignedPage() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 5 R] /Count 1 /MediaBox [0 0 300 400]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>")
        pdf.stream(4, "", "BT ET")
        let signed = try SignatureSharedRoleTests.sign(pdf, .noChanges)
        let document = try PdfDocument.open(signed)
        let page = try XCTUnwrap(document.get(3)).description.replacingOccurrences(of: "/Contents 4 0 R", with: "/Contents 30 0 R")
        var text = "\n"
        let pageAt = signed.count + text.unicodeScalars.count
        text += "3 5 obj\n\(page)\nendobj\n"
        let contentAt = signed.count + text.unicodeScalars.count
        text += "30 0 obj\n\(SignatureRawKit.streamBody(SignatureRawKit.evil))\nendobj\n"
        let table = signed.count + text.unicodeScalars.count
        text += String(format: "xref\n3 1\n%010ld 00005 n \n30 1\n%010ld 00000 n \n", pageAt, contentAt)
        text += "trailer\n<</Size 31\(SignatureRawKit.kept(document)) /Prev \(document.startXref)>>\nstartxref\n\(table)\n%%EOF\n"
        let attacked = signed + TestPdf.latin(text)

        XCTAssertTrue(try SignatureRawKit.showsEvil(attacked))
        let report = try SignatureKit.verify(attacked)[0]
        XCTAssertEqual(report.verdict, .changedAfterSigning)
        XCTAssertTrue(report.changes.notAllowed.contains { $0.kind == .pageContent })
    }
}
#endif
