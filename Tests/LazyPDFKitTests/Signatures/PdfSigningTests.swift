#if canImport(Security)
import XCTest
import Security
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Signatures/PdfSigningTests.cs: the same cases, with these differences. The
// framework that agrees with our reading of a signature is SignedCms in the C#; here it is CMSDecoder on macOS, which
// iOS does not have, and CmsVerifier on both. The C# opens the signed file with PdfPig and reads its page text; here
// the file is opened with PdfDocument and the page's content stream is read. The Turkish name is drawn with the
// synthetic font of the font program tests, which has A, B, ğ, İ and À, so the name is made of those letters
// where the C# uses Arial from the Windows fonts folder.

final class PdfSigningTests: XCTestCase {
    private let pki = Pki.instance

    private let tinyJpeg: [UInt8] = Data(base64Encoded: [
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

    private final class Fonts: FontSource {
        private let data: [UInt8]

        init() throws {
            data = try SyntheticFonts.ttf()
        }

        func find(_ family: String, _ style: FontStyles) -> FontFile? { FontFile(data) }
    }

    private func appearance(_ document: PdfDocument, _ field: String) throws -> PdfStream {
        let widget = try XCTUnwrap(PdfForm.read(document).find(field)).widgets[0]
        return try XCTUnwrap(document.stream(document.dict(widget.dictionary, "AP"), "N"))
    }

    private func play(_ file: [UInt8], _ field: String) throws -> Recorder {
        let document = try PdfDocument.open(file)
        let visitor = Recorder()
        ContentInterpreter(document).run(try appearance(document, field), visitor)
        return visitor
    }

    private func single(_ reports: [SignatureReport], line: UInt = #line) throws -> SignatureReport {
        XCTAssertEqual(reports.count, 1, line: line)
        return try XCTUnwrap(reports.first, line: line)
    }

    private func plainCertificate(_ name: String) throws -> X509Certificate {
        try SignatureExtraKit.selfSigned(subject: X509Certificate.name("CN=" + name),
                                         extensions: [CertificateBuilder.keyUsage([.digitalSignature])])
    }

    #if os(macOS)
    private func frameworkAccepts(_ cms: [UInt8], _ content: [UInt8]) -> Bool {
        var created: CMSDecoder?
        guard CMSDecoderCreate(&created) == errSecSuccess, let decoder = created,
              CMSDecoderSetDetachedContent(decoder, Data(content) as CFData) == errSecSuccess else { return false }
        let updated = cms.withUnsafeBytes { buffer -> OSStatus in
            guard let start = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, start, buffer.count)
        }
        var status = CMSSignerStatus.unsigned
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
              CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, nil, nil) == errSecSuccess else { return false }
        return status == .valid
    }
    #endif

    func test_eachKeyAndFormatSignsAndVerifies() throws {
        for kind in ["rsa", "ec", "pkcs7"] {
            var request: PdfSignRequest
            switch kind {
            case "ec":
                request = PdfSignRequest(pki.leafEc, Pki.signing)
                request.chain = pki.chain
            case "pkcs7":
                request = SignatureKit.request(pki)
                request.format = .pkcs7Detached
            default:
                request = SignatureKit.request(pki)
            }
            let original = SignatureKit.plain()
            let signed = try PdfSigner.sign(original, request)

            XCTAssertEqual(Array(signed[0..<original.count]), original, "The signature is an update: the file's own bytes stay.")
            let report = try single(SignatureKit.verify(signed))
            XCTAssertEqual(report.verdict, .valid, kind)
            XCTAssertEqual(report.signerName, kind == "ec" ? "Grace Hopper" : "Ada Lovelace", kind)
            XCTAssertEqual(report.subFilter, kind == "pkcs7" ? "adbe.pkcs7.detached" : "ETSI.CAdES.detached", kind)
            XCTAssertEqual(report.level, kind == "pkcs7" ? .none : .b, kind)
            XCTAssertEqual(report.signingTime, Pki.signing, kind)
            XCTAssertTrue(report.coversWholeFile, kind)
            XCTAssertEqual(report.fieldName, "Signature1", kind)
        }
    }

    func test_theFrameworkAgreesWithOurReadingOfTheSignature() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        let (cms, content) = SignatureKit.parts(signed)
        let parsed = try XCTUnwrap(CmsSignature.parse(cms))
        let signer = try XCTUnwrap(parsed.findSigner())

        XCTAssertEqual(CmsVerifier.check(parsed, signer) { SignatureCrypto.hash($0, content) }, .ok)
        XCTAssertEqual(signer.thumbprint, pki.leaf.thumbprint)
        #if os(macOS)
        XCTAssertTrue(frameworkAccepts(cms, content))
        #endif

        var tampered = content
        tampered[tampered.count / 2] ^= 1
        XCTAssertEqual(CmsVerifier.check(parsed, signer) { SignatureCrypto.hash($0, tampered) }, .digestMismatch)
        #if os(macOS)
        XCTAssertFalse(frameworkAccepts(cms, tampered))
        #endif
    }

    func test_theByteRangeLeavesExactlyTheContentsOutAndTheFileReopens() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))

        let found = SignatureScan.find(signed)
        XCTAssertEqual(found.count, 1)
        let range = SignatureKit.byteRange(found[0])
        XCTAssertEqual(range[0], 0)
        XCTAssertEqual(signed[range[1]], UInt8(ascii: "<"))
        XCTAssertEqual(signed[range[2] - 1], UInt8(ascii: ">"))
        XCTAssertEqual(range[2] + range[3], signed.count)

        let document = try PdfDocument.open(signed)
        XCTAssertTrue(document.isSigned)
        XCTAssertTrue(document.repairs.isEmpty)
        XCTAssertEqual(document.pages.count, 2)
        XCTAssertTrue(SignatureKit.text(try document.pages[0].contents()).contains("Contract page 1"))
    }

    func test_aVisibleSignatureDrawsItsTextInTheRectangle() throws {
        var request = SignatureKit.request(pki)
        request.rect = PdfRect(20, 20, 230, 90)
        request.reason = "I approve"
        request.location = "Ankara"
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)

        XCTAssertEqual(try single(SignatureKit.verify(signed)).verdict, .valid)
        let document = try PdfDocument.open(signed)
        let field = try XCTUnwrap(PdfForm.read(document).find("Signature1"))
        XCTAssertEqual(field.widgets[0].rect, PdfRect(20, 20, 230, 90))
        XCTAssertEqual(field.widgets[0].pageIndex, 0)
        let shown = try play(signed, "Signature1").text
        XCTAssertTrue(shown.contains("Digitally signed by Ada Lovelace"), shown)
        XCTAssertTrue(shown.contains("I approve"), shown)
        XCTAssertTrue(shown.contains("Ankara"), shown)
        XCTAssertEqual(document.rect(try appearance(document, "Signature1").dictionary, "BBox"), PdfRect(0, 0, 210, 70))
    }

    func test_aPictureOrInkGoesBesideTheText() throws {
        var pictureLook = SignatureLook()
        pictureLook.jpeg = tinyJpeg
        var picture = SignatureKit.request(pki)
        picture.rect = PdfRect(10, 10, 250, 90)
        picture.look = pictureLook
        let visitor = try play(PdfSigner.sign(SignatureKit.plain(), picture), "Signature1")
        XCTAssertEqual(visitor.images.count, 1)
        XCTAssertTrue(visitor.text.contains("Digitally signed"), visitor.text)

        var inkLook = SignatureLook()
        inkLook.ink = [[(x: 0, y: 0), (x: 0.5, y: 1), (x: 1, y: 0.2)], [(x: 0.2, y: 0.5), (x: 0.8, y: 0.5)]]
        inkLook.text = ""
        var ink = SignatureKit.request(pki)
        ink.rect = PdfRect(10, 10, 250, 90)
        ink.look = inkLook
        let drawn = try play(PdfSigner.sign(SignatureKit.plain(), ink), "Signature1")
        XCTAssertEqual(drawn.paths.count, 2)
        XCTAssertEqual(drawn.text, "")
    }

    func test_turkishNamesAreEmbeddedFromTheFontSource() throws {
        let name = "ABğİÀ"
        let certificate = try plainCertificate(name)

        var sign = PdfSignRequest(certificate, Pki.signing)
        sign.rect = PdfRect(10, 10, 250, 60)
        sign.fonts = try Fonts()
        let signed = try PdfSigner.sign(SignatureKit.plain(), sign)

        let shown = try play(signed, "Signature1").text
        XCTAssertTrue(shown.contains(name), shown.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        XCTAssertEqual(try single(SignatureKit.verify(signed)).signerName, name)
    }

    func test_textNoFontCanDrawIsRefusedBeforeAnythingChanges() throws {
        let certificate = try plainCertificate("Şeyma")
        var request = PdfSignRequest(certificate, Pki.signing)
        request.rect = PdfRect(10, 10, 250, 60)

        let message = SignatureExtraKit.invalidOperation(try PdfSigner.sign(SignatureKit.plain(), request))

        XCTAssertEqual(message, SignatureText.noFont)
    }

    func test_anEmptySignatureFieldIsSignedWhereItStands() throws {
        let document = try PdfDocument.open(SignatureKit.plain())
        _ = try PdfForm.read(document).addField(FieldSpec(.signature, "Approval", 1, PdfRect(30, 30, 200, 80)))
        let session = try PdfEditSession.open(document.saveIncremental())

        var request = SignatureKit.request(pki)
        request.fieldName = "Approval"
        try PdfSigner.sign(session, request)

        let report = try single(SignatureKit.verify(session.current))
        XCTAssertEqual(report.fieldName, "Approval")
        XCTAssertEqual(report.verdict, .valid)
        let form = PdfForm.read(session.document)
        let field = try XCTUnwrap(form.find("Approval"))
        XCTAssertEqual(field.widgets[0].pageIndex, 1)
        XCTAssertTrue(field.isSigned)
        XCTAssertEqual(form.fields.count, 1)
        XCTAssertTrue(try play(session.current, "Approval").text.contains("Digitally signed"))
    }

    func test_aFieldThatIsSignedOrNotASignatureFieldIsRefused() throws {
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        var again = SignatureKit.request(pki)
        again.fieldName = "Signature1"
        XCTAssertEqual(SignatureExtraKit.invalidOperation(try PdfSigner.sign(signed, again)), SignatureText.fieldTaken)

        let document = try PdfDocument.open(SignatureKit.plain())
        _ = try PdfForm.read(document).addField(FieldSpec(.text, "Name", 0, PdfRect(30, 30, 200, 60)))
        let withText = try document.saveIncremental()
        var named = SignatureKit.request(pki)
        named.fieldName = "Name"
        _ = SignatureExtraKit.invalidOperation(try PdfSigner.sign(withText, named))
    }

    func test_aSecondSignatureLeavesTheFirstValid() throws {
        let first = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        var request = PdfSignRequest(pki.leafEc, try XCTUnwrap(Pki.signing.adding(days: 1)))
        request.chain = pki.chain
        request.rect = PdfRect(20, 20, 200, 60)
        let second = try PdfSigner.sign(first, request)

        let reports = try SignatureKit.verify(second)
        XCTAssertEqual(reports.count, 2)
        for report in reports { XCTAssertEqual(report.verdict, .valid) }
        XCTAssertEqual(reports.map { $0.fieldName }, ["Signature1", "Signature2"])
        XCTAssertFalse(reports[0].coversWholeFile)
        XCTAssertTrue(reports[1].coversWholeFile)
        XCTAssertTrue(reports[0].changes.changes.contains { $0.kind == .signature && $0.allowed })
        XCTAssertEqual(reports[0].changes.revisionsAfter, 1)
    }

    func test_certifyingWritesDocMDPAndOnlyTheFirstSignatureMayDoIt() throws {
        var request = SignatureKit.request(pki)
        request.certify = .formFill
        let certified = try PdfSigner.sign(SignatureKit.plain(), request)

        let report = try single(SignatureKit.verify(certified))
        XCTAssertEqual(report.kind, .certification)
        XCTAssertEqual(report.certification, .formFill)
        XCTAssertTrue(try PdfDocument.open(certified).isCertified)

        XCTAssertEqual(SignatureExtraKit.invalidOperation(try PdfSigner.sign(certified, request)), SignatureText.notCertifiable)
        let signed = try PdfSigner.sign(SignatureKit.plain(), SignatureKit.request(pki))
        XCTAssertEqual(SignatureExtraKit.invalidOperation(try PdfSigner.sign(signed, request)), SignatureText.notCertifiable)
    }

    func test_aFieldLockIsWrittenAsFieldMDPOnTheSignature() throws {
        var request = SignatureKit.request(pki)
        request.lock = FieldLock(.include, ["Name", "Date"])
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)

        let document = try PdfDocument.open(signed)
        let signature = try XCTUnwrap(document.dict(try XCTUnwrap(PdfForm.read(document).find("Signature1")).dictionary, "V"))
        let reference = try XCTUnwrap(document.resolve(try XCTUnwrap(document.array(signature, "Reference")).items[0]) as? PdfDictionary)
        XCTAssertEqual(document.name(reference, "TransformMethod"), "FieldMDP")
        let parameters = try XCTUnwrap(document.dict(reference, "TransformParams"))
        XCTAssertEqual(document.name(parameters, "Action"), "Include")
        XCTAssertEqual(try XCTUnwrap(document.array(parameters, "Fields")).items.map { PdfText.read(document, $0) }, ["Name", "Date"])
        XCTAssertEqual(try single(SignatureKit.verify(signed)).verdict, .valid)
    }

    func test_aClearedFieldCanBeSignedAgainWhateverTheClearedSignatureLocked() throws {
        var request = SignatureKit.request(pki)
        request.fieldName = "Signature1"
        request.lock = FieldLock(.all, [])
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)
        let document = try PdfDocument.open(signed)
        let form = PdfForm.read(document)
        try form.clearSignature(try XCTUnwrap(form.find("Signature1")))

        request.lock = nil
        let again = try PdfSigner.sign(document.saveIncremental(), request)

        XCTAssertTrue(try XCTUnwrap(PdfForm.read(PdfDocument.open(again)).find("Signature1")).isSigned)
    }

    func test_aClearedCertificationLetsTheFileBeCertifiedAgain() throws {
        var request = SignatureKit.request(pki)
        request.fieldName = "Signature1"
        request.certify = .formFill
        let certified = try PdfSigner.sign(SignatureKit.plain(), request)
        let document = try PdfDocument.open(certified)
        let form = PdfForm.read(document)
        try form.clearSignature(try XCTUnwrap(form.find("Signature1")))

        let again = try PdfSigner.sign(document.saveIncremental(), request)

        XCTAssertTrue(try PdfDocument.open(again).isCertified)
    }

    func test_aHashSignerStandsInForAKeyThatIsNotHere() throws {
        for ec in [false, true] {
            let source = ec ? pki.leafEc : pki.leaf
            let publicOnly = try XCTUnwrap(X509Certificate(source.rawData))
            var calls: [String] = []
            let signer: PdfHashSigner = { hash, algorithm in
                calls.append(algorithm.rawValue)
                let key = try XCTUnwrap(source.privateKey)
                let made = try SignatureCrypto.sign(key, hash, algorithm, ec: ec)
                return ec ? SignatureExtraKit.p1363(made) : made
            }

            var request = PdfSignRequest(publicOnly, Pki.signing)
            request.chain = pki.chain
            request.signer = signer
            request.digest = .sha384
            let signed = try PdfSigner.sign(SignatureKit.plain(), request)

            XCTAssertEqual(calls, ["SHA384"], "\(ec)")
            XCTAssertEqual(try single(SignatureKit.verify(signed)).verdict, .valid, "\(ec)")
        }
    }

    func test_aCertificateWithoutAKeyOrASignerIsRefused() throws {
        let publicOnly = try XCTUnwrap(X509Certificate(pki.leaf.rawData))
        let message = SignatureExtraKit.invalidOperation(try PdfSigner.sign(SignatureKit.plain(), PdfSignRequest(publicOnly, Pki.signing)))
        XCTAssertEqual(message, SignatureText.noPrivateKey)

        var sha1 = SignatureKit.request(pki)
        sha1.digest = .sha1
        SignatureExtraKit.argumentException(try PdfSigner.sign(SignatureKit.plain(), sha1))
        var page = SignatureKit.request(pki)
        page.rect = PdfRect(1, 1, 50, 50)
        page.pageIndex = 9
        SignatureExtraKit.argumentException(try PdfSigner.sign(SignatureKit.plain(), page))
    }

    func test_aSignatureThatOutgrowsItsRoomIsRetriedWithMore() throws {
        var request = SignatureKit.request(pki)
        request.reserveBytes = 64
        let signed = try PdfSigner.sign(SignatureKit.plain(), request)

        XCTAssertEqual(try single(SignatureKit.verify(signed)).verdict, .valid)
        let contents = try XCTUnwrap(SignatureScan.find(signed)[0].dictionary["Contents"] as? PdfString).bytes
        XCTAssertTrue(contents.count > 64)
    }

    func test_signingASessionIsOneStepThatUndoTakesBack() throws {
        let session = try PdfEditSession.open(SignatureKit.plain())
        let before = session.current

        try PdfSigner.sign(session, SignatureKit.request(pki))

        XCTAssertEqual(session.undoLabel, "Sign")
        XCTAssertEqual(try single(PdfSignatureVerifier.verify(session, pki.trusting)).verdict, .valid)
        XCTAssertTrue(try session.undo())
        XCTAssertEqual(session.current, before)
        XCTAssertTrue(try session.redo())
        XCTAssertEqual(try single(PdfSignatureVerifier.verify(session, pki.trusting)).verdict, .valid)
    }

    func test_anEncryptedFileIsSignedWithItsOwnKeys() throws {
        for strength in [PdfCryptStrength.aes128, .aes256] {
            let id = [UInt8](repeating: 0, count: 16)
            let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .all, strength: strength, firstId: id, random: SeededRandom(1))
            let encrypted = try PdfDocument.open(SignatureKit.plain()).saveRewrite(PdfSaveOptions(security: security, documentId: id))
            XCTAssertTrue(try PdfDocument.open(encrypted).isEncrypted)

            var request = SignatureKit.request(pki)
            request.rect = PdfRect(20, 20, 230, 90)
            request.reason = "Because"
            let signed = try PdfSigner.sign(encrypted, request)

            let report = try single(SignatureKit.verify(signed))
            XCTAssertEqual(report.verdict, .valid, "\(strength)")
            XCTAssertEqual(report.reason, "Because", "\(strength)")
            XCTAssertEqual(report.signerName, "Ada Lovelace", "\(strength)")
            XCTAssertTrue(try play(signed, "Signature1").text.contains("Because"), "\(strength)")
        }
    }

    func test_aFileWithADamagedCrossReferenceIsSignedByAFullUpdate() throws {
        let damaged = TestPdf.replace(SignatureKit.plain(), "startxref\n", "startxref\n9")
        XCTAssertTrue(try PdfDocument.open(damaged).xrefRebuilt)

        let signed = try PdfSigner.sign(damaged, SignatureKit.request(pki))

        XCTAssertFalse(try PdfDocument.open(signed).xrefRebuilt)
        XCTAssertEqual(try single(SignatureKit.verify(signed)).verdict, .valid)
    }

    func test_anEcdsaValueWithLeadingZeroBytesIsWrittenAsAProperInteger() throws {
        let publicOnly = try XCTUnwrap(X509Certificate(pki.leafEc.rawData))
        var raw = [UInt8](repeating: 0, count: 64)
        raw[31] = 5
        raw[34] = 0x80
        var request = PdfSignRequest(publicOnly, Pki.signing)
        request.chain = pki.chain
        request.signer = { _, _ in raw }

        let signed = try PdfSigner.sign(SignatureKit.plain(), request)

        let cms = try XCTUnwrap(CmsSignature.parse(SignatureKit.parts(signed).cms))
        var outer = AsnReader(cms.signature)
        var sequence = try outer.readSequence()
        XCTAssertEqual(try sequence.readInteger(), AsnInteger(5))
        XCTAssertEqual(try single(SignatureKit.verify(signed)).verdict, .broken)
    }
}
#endif
