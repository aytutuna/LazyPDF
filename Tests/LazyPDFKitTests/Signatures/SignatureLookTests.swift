#if canImport(Security)
import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/SignatureLookTests.cs: the same cases.

final class SignatureLookTests: XCTestCase {
    private let pki = Pki.instance

    private let jpeg: [UInt8] = Data(base64Encoded: [
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19i",
        "Z2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2Nj",
        "Y2NjY2NjY2P/wAARCAAIABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF",
        "BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW",
        "V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi",
        "4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC",
        "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm",
        "Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq",
        "8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDHrPoortyj7fy/U9HNPsfP9D//2Q=="
    ].joined()).map { [UInt8]($0) } ?? []

    private let scribble: [[(x: Double, y: Double)]] = [[(x: 0, y: 0), (x: 0.5, y: 1), (x: 1, y: 0.2)], [(x: 0.2, y: 0.5), (x: 0.8, y: 0.5)]]

    private func appearance(_ document: PdfDocument, _ field: String = "Signature1") throws -> PdfStream {
        let widget = try XCTUnwrap(PdfForm.read(document).find(field)).widgets[0]
        return try XCTUnwrap(document.stream(document.dict(widget.dictionary, "AP"), "N"))
    }

    private func play(_ file: [UInt8], _ field: String = "Signature1") throws -> Recorder {
        let document = try PdfDocument.open(file)
        let seen = Recorder()
        ContentInterpreter(document).run(try appearance(document, field), seen)
        return seen
    }

    private func hasImageObject(_ file: [UInt8]) -> Bool {
        SignatureKit.text(file).range(of: "/Subtype\\s*/Image", options: .regularExpression) != nil
    }

    private func resources(_ file: [UInt8]) throws -> PdfDictionary? {
        let document = try PdfDocument.open(file)
        return document.dict(try appearance(document).dictionary, "Resources")
    }

    private func usesFont(_ file: [UInt8]) throws -> Bool { try resources(file)?.containsKey("Font") ?? false }

    private func sign(_ rect: PdfRect, _ look: SignatureLook, _ file: [UInt8]? = nil, rotate: Int = 0) throws -> [UInt8] {
        var file = try file ?? SignatureKit.plain()
        if rotate != 0 {
            let document = try PdfDocument.open(file)
            document.pages[0].dictionary["Rotate"] = PdfNumber(rotate)
            file = try document.saveIncremental()
        }
        var request = SignatureKit.request(pki)
        request.rect = rect
        request.look = look
        let signed = try PdfSigner.sign(file, request)
        let reports = try SignatureKit.verify(signed)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.verdict, .valid)
        return signed
    }

    private func second(_ rect: PdfRect) throws -> PdfSignRequest {
        var request = PdfSignRequest(pki.leafEc, try XCTUnwrap(Pki.signing.adding(days: 1)))
        request.chain = pki.chain
        request.rect = rect
        request.look = graphic("jpeg")
        return request
    }

    private func graphic(_ kind: String, _ text: String? = nil) -> SignatureLook {
        var look = SignatureLook()
        if kind == "jpeg" { look.jpeg = jpeg } else { look.ink = scribble }
        look.text = text
        return look
    }

    func test_aBoxTooShortForTheMarginsShowsNeitherPictureNorText() throws {
        for kind in ["jpeg", "ink"] {
            let signed = try sign(PdfRect(20, 20, 240, 25), graphic(kind))

            XCTAssertFalse(hasImageObject(signed), kind)
            let seen = try play(signed)
            XCTAssertEqual(seen.images.count, 0, kind)
            XCTAssertEqual(seen.paths.count, 0, kind)
            XCTAssertEqual(seen.text, "", kind)
            XCTAssertFalse(try usesFont(signed), kind)
        }
    }

    func test_aFieldTooNarrowForThePictureGivesTheTextTheWholeWidth() throws {
        for kind in ["jpeg", "ink"] {
            let signed = try sign(PdfRect(20, 20, 32, 120), graphic(kind))

            XCTAssertFalse(hasImageObject(signed), kind)
            let seen = try play(signed)
            XCTAssertEqual(seen.images.count, 0, kind)
            XCTAssertEqual(seen.paths.count, 0, kind)
            XCTAssertNotEqual(seen.text, "", kind)
        }
    }

    func test_pictureOnlyIntoAFieldWithNoRoomIsABlankForm() throws {
        for kind in ["jpeg", "ink"] {
            let signed = try sign(PdfRect(20, 20, 40, 25), graphic(kind, ""))

            XCTAssertFalse(hasImageObject(signed), kind)
            XCTAssertFalse(try usesFont(signed), kind)
            XCTAssertFalse(try resources(signed)?.containsKey("XObject") ?? false, kind)
            let seen = try play(signed)
            XCTAssertEqual(seen.images.count + seen.paths.count, 0, kind)
        }
    }

    func test_aShortBoxWithTheDefaultTextDrawsNoTextAndEmbedsNoFont() throws {
        let signed = try sign(PdfRect(20, 20, 240, 25), SignatureLook())

        XCTAssertEqual(try play(signed).text, "")
        XCTAssertFalse(try usesFont(signed))
    }

    func test_aNarrowFieldWithRoomForBothDrawsThePictureAndTheText() throws {
        let signed = try sign(PdfRect(20, 20, 80, 120), graphic("jpeg"))

        XCTAssertTrue(hasImageObject(signed))
        let seen = try play(signed)
        XCTAssertEqual(seen.images.count, 1)
        XCTAssertNotEqual(seen.text, "")
    }

    func test_aPictureIsDrawnOnATurnedPage() throws {
        for rotate in [0, 90, 180, 270] {
            let signed = try sign(PdfRect(20, 20, 250, 90), graphic("jpeg"), rotate: rotate)

            XCTAssertEqual(try play(signed).images.count, 1, "\(rotate)")
            if rotate != 0 { XCTAssertTrue(try appearance(PdfDocument.open(signed)).dictionary.containsKey("Matrix"), "\(rotate)") }
        }
    }

    func test_aPictureKeepsTheRectangleOfAnEmptyField() throws {
        let document = try PdfDocument.open(SignatureKit.plain())
        _ = try PdfForm.read(document).addField(FieldSpec(.signature, "Approval", 1, PdfRect(30, 30, 200, 80)))
        let session = try PdfEditSession.open(document.saveIncremental())
        var request = SignatureKit.request(pki)
        request.fieldName = "Approval"
        request.look = graphic("jpeg")

        try PdfSigner.sign(session, request)

        let signed = session.current
        let reports = try SignatureKit.verify(signed)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.verdict, .valid)
        XCTAssertEqual(try PdfForm.read(PdfDocument.open(signed)).find("Approval")?.widgets[0].rect, PdfRect(30, 30, 200, 80))
        XCTAssertEqual(try play(signed, "Approval").images.count, 1)
    }

    func test_aPictureIsSignedIntoAFileWithLimitedPermissions() throws {
        let id = [UInt8](repeating: 0, count: 16)
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: [.print, .copy], strength: .aes256, firstId: id, random: SeededRandom(3))
        let limited = try PdfDocument.open(SignatureKit.plain()).saveRewrite(PdfSaveOptions(security: security, documentId: id))

        let signed = try sign(PdfRect(20, 20, 250, 90), graphic("jpeg"), limited)

        XCTAssertEqual(try play(signed).images.count, 1)
    }

    func test_aSecondPictureSignatureLeavesTheFirstOneValidOnAFormFillingFile() throws {
        var request = SignatureKit.request(pki)
        request.rect = PdfRect(10, 10, 120, 40)
        let first = try PdfSigner.sign(SignatureTestHelpers.formFile(), request)

        let signed = try PdfSigner.sign(first, second(PdfRect(10, 50, 250, 90)))

        let reports = try SignatureKit.verify(signed)
        for report in reports { XCTAssertEqual(report.verdict, .valid) }
        XCTAssertFalse(reports[0].changes.changes.contains { !$0.allowed })
        XCTAssertTrue(hasImageObject(signed))
    }

    func test_aPictureSignatureAfterACertificationThatAllowsFillingChangesNothingIllegal() throws {
        let signed = try PdfSigner.sign(SignatureTestHelpers.certified(.formFill), second(PdfRect(10, 50, 250, 90)))

        let reports = try SignatureKit.verify(signed)
        XCTAssertEqual(reports.count, 2)
        for report in reports { XCTAssertEqual(report.verdict, .valid) }
        XCTAssertFalse(reports[0].changes.changes.contains { !$0.allowed })
    }

    func test_fillingAFormAfterACertificationWithAPictureChangesNothingIllegal() throws {
        var request = SignatureKit.request(pki)
        request.certify = .formFill
        request.rect = PdfRect(10, 10, 250, 90)
        request.look = graphic("jpeg")
        let signed = try PdfSigner.sign(SignatureTestHelpers.formFile(), request)

        let filled = try SignatureTestHelpers.edit(signed) { d in _ = try PdfForm.read(d).setValue("Name", "Ada Lovelace") }

        let report = try SignatureTestHelpers.first(filled)
        XCTAssertEqual(report.verdict, .valid)
        XCTAssertFalse(report.changes.changes.contains { !$0.allowed })
    }
}
#endif
