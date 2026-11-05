import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/CryptFilterTests.cs: the same cases.

final class CryptFilterTests: XCTestCase {
    private static let fileId: [UInt8] = (1...16).map { UInt8($0) }

    private func handler(_ strength: PdfCryptStrength = .aes128, _ owner: String = "owner") -> PdfSecurity {
        PdfSecurity.create(userPassword: "", ownerPassword: owner, permissions: .all, strength: strength,
                           firstId: Self.fileId, random: SeededRandom(7))
    }

    /// A one-page AES-128 file whose content stream (object 6) has the given dictionary entries and is stored by `store`.
    private func encrypted(_ entries: String, filterObject: String? = nil, encryptEntries: String = "",
                           more: ((TestPdf, PdfSecurity) -> Void)? = nil,
                           store: (PdfSecurity, PdfDictionary) throws -> [UInt8]) throws -> (file: [UInt8], security: PdfSecurity) {
        let security = handler()
        let pdf = TestPdf("%PDF-1.6\n")
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /MediaBox [0 0 50 50]>>")
        if let filterObject { pdf.obj(9, filterObject) }
        pdf.stream(6, entries, try store(security, try FilterFixtures.dict("<< \(entries) >>")))
        more?(pdf, security)
        pdf.obj(8, String(security.dictionary.description.dropLast(2)) + encryptEntries + ">>")
        let id = Hex.string(Self.fileId)
        return (pdf.finish("/Root 1 0 R /Encrypt 8 0 R /ID [<\(id)> <\(id)>]"), security)
    }

    private func contents(_ file: [UInt8]) throws -> String {
        let document = try PdfDocument.open(file)
        return TestPdf.text(document.pages[0].contents())
    }

    func test_streamWithANamedCryptFilterIsDecodedAfterDecryption() throws {
        let (file, _) = try encrypted("/Filter [/Crypt /FlateDecode] /DecodeParms [<</Name /StdCF>> null]") { s, d in
            s.encryptStream(6, 0, TestPdf.deflate(TestPdf.latin("0 0 m")), d)
        }
        let document = try PdfDocument.open(file)
        XCTAssertEqual(TestPdf.text(try document.data(try XCTUnwrap(document.get(6) as? PdfStream))), "0 0 m")
        XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "0 0 m")
    }

    func test_indirectFilterPicksTheSameCipherOnWritingAsOnReading() throws {
        let (file, _) = try encrypted("/Filter 9 0 R /DecodeParms [<</Name /Identity>>]", filterObject: "[/Crypt]") { _, _ in
            TestPdf.latin("HELLO")
        }
        let document = try PdfDocument.open(file)
        XCTAssertEqual(TestPdf.text(document.pages[0].contents()), "HELLO")
        XCTAssertEqual(try contents(try document.saveRewrite(PdfSaveOptions(security: document.security))), "HELLO")

        try XCTUnwrap(document.get(6) as? PdfStream).dictionary["Touched"] = PdfNumber(1)
        XCTAssertEqual(try contents(try document.saveIncremental()), "HELLO")
    }

    func test_rewriteWithAnotherHandlerDropsTheCryptFilter() throws {
        let (file, _) = try encrypted("/Filter /Crypt /DecodeParms <</Name /StdCF>>") { s, d in
            s.encryptStream(6, 0, TestPdf.latin("q Q"), d)
        }
        let document = try PdfDocument.open(file)

        let plain = try document.saveRewrite()
        XCTAssertFalse(TestPdf.text(plain).contains("Crypt"))
        let reopened = try PdfDocument.open(plain)
        let stream = try XCTUnwrap(reopened.resolve(reopened.pages[0].dictionary["Contents"]) as? PdfStream)
        XCTAssertEqual(TestPdf.text(try reopened.data(stream)), "q Q")

        let again = try document.saveRewrite(PdfSaveOptions(security: handler(.aes256, "other")))
        XCTAssertEqual(try contents(again), "q Q")
    }

    func test_parametersThatNameAStreamSurviveDroppingTheCryptFilter() throws {
        let (file, _) = try encrypted("/Filter [/Crypt /JBIG2Decode] /DecodeParms [<</Name /Identity>> <</JBIG2Globals 7 0 R>>]",
                                      more: { pdf, s in pdf.stream(7, "", s.encryptStream(7, 0, TestPdf.latin("globals"), PdfDictionary())) }) { _, _ in
            TestPdf.latin("HELLO")
        }
        let document = try PdfDocument.open(file)

        let plain = try document.saveRewrite()
        XCTAssertFalse(TestPdf.text(plain).contains("Crypt"))
        let reopened = try PdfDocument.open(plain)
        let contents = try XCTUnwrap(reopened.resolve(reopened.pages[0].dictionary["Contents"]) as? PdfStream)
        let list = try XCTUnwrap(reopened.resolve(contents.dictionary["DecodeParms"]) as? PdfArray)
        let parameters = try XCTUnwrap(reopened.resolve(list.items[0]) as? PdfDictionary)
        XCTAssertTrue(parameters["JBIG2Globals"] is PdfReference)
        let globals = try XCTUnwrap(reopened.resolve(parameters["JBIG2Globals"]) as? PdfStream)
        XCTAssertEqual(TestPdf.text(reopened.rawData(globals)), "globals")
    }

    func test_aStreamInTheEncryptDictionaryDoesNotStopAKeptHandlerFromSaving() throws {
        let (file, _) = try encrypted("", encryptEntries: " /Junk 7 0 R",
                                      more: { pdf, s in pdf.stream(7, "", s.encryptStream(7, 0, TestPdf.latin("junk"), PdfDictionary())) }) { s, d in
            s.encryptStream(6, 0, TestPdf.latin("q Q"), d)
        }
        let document = try PdfDocument.open(file)
        XCTAssertNotNil(document.security)
        XCTAssertEqual(try contents(try document.saveRewrite(PdfSaveOptions(security: document.security))), "q Q")
        XCTAssertEqual(try contents(try document.saveRewrite(PdfSaveOptions(useObjectStreams: true, security: document.security))), "q Q")
    }

    func test_embeddedFilesUseTheCryptFilterNamedByEff() throws {
        let original = handler()
        let dictionary = original.dictionary
        dictionary["StmF"] = PdfName("Identity")
        dictionary["StrF"] = PdfName("Identity")
        dictionary["EFF"] = PdfName("StdCF")
        let reader = try XCTUnwrap(try PdfSecurity.open(dictionary, Self.fileId, ""))

        let stored = original.encryptStream(5, 0, TestPdf.latin("attachment"), PdfDictionary())
        let attachment = try FilterFixtures.dict("<< /Type /EmbeddedFile >>")
        XCTAssertEqual(TestPdf.text(reader.decryptStream(5, 0, stored, attachment)), "attachment")
        XCTAssertEqual(reader.decryptStream(5, 0, stored, PdfDictionary()), stored)
    }

    func test_aes128WithAShortKeyIsRefusedWhenTheHandlerOpens() throws {
        let dictionary = SyntheticEncryption.legacy(4, 3, 40, "", "o", cfm: "AESV2").dictionary
        assertReadFails(try PdfSecurity.open(dictionary, SyntheticEncryption.id, ""), .unsupported)
    }

    func test_updatesKeepTheFirstIdThatTheKeyWasMadeFrom() throws {
        let built = SyntheticEncryption.legacy(2, 3, 128, "", "owner")
        let id = Hex.string(SyntheticEncryption.id)
        let pdf = TestPdf.withPages(1)
        pdf.obj(9, "[<\(id)> <\(id)>]")
        let file = pdf.finish("/Root 1 0 R /ID 9 0 R /Encrypt \(built.dictionary.description)")

        let document = try PdfDocument.open(file)
        XCTAssertTrue(document.isEncrypted)
        document.catalog["Touched"] = PdfNumber(1)
        XCTAssertTrue(try PdfDocument.open(document.saveIncremental()).isEncrypted)
        XCTAssertTrue(try PdfDocument.open(document.saveRewrite(PdfSaveOptions(security: document.security))).isEncrypted)
    }
}
