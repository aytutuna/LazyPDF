import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAConverterTests.cs: the same cases. The lines that read the output with
// PdfPig (PigText) have no twin, nor has the PdfPig line of TheOutputOpensInPdfPigAndTheValidatorAgreesWithTheConversion; the
// text of the converted fonts is checked through PdfFont. The fonts come from SystemFonts, which here makes them.

final class PdfAConverterTests: XCTestCase {
    private func convert(_ file: [UInt8], _ level: PdfALevel = .a2b, password: String? = nil) throws -> PdfAConversion {
        try PdfAConverter(SystemFonts()).convert(file, level, StandardsKit.date, password)
    }

    private func clean(_ result: PdfAConversion) throws -> [UInt8] {
        XCTAssertNil(result.refusal)
        let bytes = try XCTUnwrap(result.bytes)
        XCTAssertTrue(result.remaining.isEmpty, result.remaining.map { "\($0.clause) \($0.where): \($0.message)" }.joined(separator: "\n"))
        return bytes
    }

    /// A page showing text in plain Helvetica, as a word processor from long ago would make it; `extra` adds objects from number 6.
    private func plain(_ content: String = "BT /F1 12 Tf 20 100 Td (Hello world) Tj ET", catalog: String = "", page: String = "", resources: String = "",
                       extra: ((TestPdf) -> Void)? = nil, trailer: String = "") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> \(resources)>> \(page)>>")
        pdf.stream(4, "", content)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        extra?(pdf)
        return pdf.finish("/Root 1 0 R " + trailer)
    }

    private func fontOf(_ document: PdfDocument) throws -> PdfFont {
        let fonts = try XCTUnwrap(document.dict(document.pages[0].resources, "Font"))
        return PdfFont.get(document, try XCTUnwrap(document.resolve(fonts["F1"]) as? PdfDictionary))
    }

    func test_plainTextBecomesAPdfA2bFileThatStillReadsTheSame() throws {
        let result = try convert(plain())
        let file = try clean(result)
        let document = try PdfDocument.open(file)
        XCTAssertEqual(document.pdfAPart, 2)
        XCTAssertEqual(document.pdfAConformance, "B")
        XCTAssertTrue(result.changes.contains { $0.contains("embedded") })
        let font = try fontOf(document)
        XCTAssertTrue(font.isEmbedded)
        XCTAssertEqual(font.toText(Array("Hello world".utf8)), "Hello world")
    }

    func test_everyLevelConvertsToAFileThatNamesItself() throws {
        let cases: [(PdfALevel, String, Int, String?)] = [
            (.a1b, "%PDF-1.4", 1, "B"), (.a2b, "%PDF-1.7", 2, "B"), (.a2u, "%PDF-1.7", 2, "U"),
            (.a3b, "%PDF-1.7", 3, "B"), (.a3u, "%PDF-1.7", 3, "U"), (.a4, "%PDF-2.0", 4, nil),
        ]
        for (level, header, part, conformance) in cases {
            let file = try clean(try convert(plain(), level))
            XCTAssertTrue(StandardsKit.latin(file).hasPrefix(header), "\(level)")
            let document = try PdfDocument.open(file)
            XCTAssertEqual(document.pdfAPart, part, "\(level)")
            XCTAssertEqual(document.pdfAConformance, conformance, "\(level)")
        }
    }

    func test_levelUGetsAToUnicodeMapForItsFonts() throws {
        let file = try clean(try convert(plain(), .a2u))
        let document = try PdfDocument.open(file)
        XCTAssertTrue(try fontOf(document).hasToUnicode)
    }

    func test_convertingTwiceChangesNothingThatMatters() throws {
        let once = try clean(try convert(plain()))
        let twice = try clean(try convert(once))
        let document = try PdfDocument.open(twice)
        XCTAssertEqual(try fontOf(document).toText(Array("Hello world".utf8)), "Hello world")
    }

    func test_part1RefusesTransparencyAndSaysWhy() throws {
        let file = plain("/GS gs 0 g 0 0 50 50 re f", resources: "/ExtGState <</GS <</ca 0.5>>>>")
        let result = try convert(file, .a1b)
        XCTAssertNil(result.bytes)
        XCTAssertTrue(try XCTUnwrap(result.refusal).contains("transparency"))
        XCTAssertTrue(try XCTUnwrap(result.refusal).contains("PDF/A-2"))
    }

    func test_part1DropsAGroupThatNothingOnThePageNeeds() throws {
        let result = try convert(plain(page: "/Group << /S /Transparency /CS /DeviceRGB >>"), .a1b)
        _ = try clean(result)
        XCTAssertTrue(result.changes.contains { $0.contains("transparency groups") })
    }

    func test_part2KeepsTransparency() throws {
        _ = try clean(try convert(plain("/GS gs 0 g 0 0 50 50 re f", resources: "/ExtGState <</GS <</ca 0.5>>>>")))
    }

    private func lock(_ file: [UInt8], _ user: String, _ owner: String, _ permissions: PdfPermissions) throws -> [UInt8] {
        let id = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let document = try PdfDocument.open(file)
        let security = PdfSecurity.create(userPassword: user, ownerPassword: owner, permissions: permissions, strength: .aes256, firstId: id)
        return try document.saveRewrite(PdfSaveOptions(security: security, documentId: id))
    }

    func test_aFileThatIsNotAPdfOrNeedsAPasswordIsRefused() throws {
        XCTAssertTrue(try XCTUnwrap(try convert(Array("not a pdf".utf8)).refusal).contains("could not be read"))
        let locked = try lock(plain(), "user", "owner", .all)
        XCTAssertTrue(try XCTUnwrap(try convert(locked, password: "wrong").refusal).contains("password"))
    }

    func test_encryptionIsRemovedWhenTheRightsAreThere() throws {
        let owner = try lock(plain(), "user", "owner", .print)
        let file = try clean(try convert(owner, password: "owner"))
        let document = try PdfDocument.open(file)
        XCTAssertFalse(document.isEncrypted)

        let open = try lock(plain(), "user", "owner", .all)
        XCTAssertNotNil(try convert(open, password: "user").bytes)
    }

    func test_aUserWhoMayNotModifyTheFileCannotHaveItConverted() throws {
        let locked = try lock(plain(), "user", "owner", .print)
        let result = try convert(locked, password: "user")
        XCTAssertNil(result.bytes)
        XCTAssertTrue(try XCTUnwrap(result.refusal).contains("permissions"))
    }

    func test_actionsAndScriptsAreRemoved() throws {
        let file = plain(catalog: "/OpenAction << /S /JavaScript /JS (1) >> /AA << /WC << /S /URI /URI (x) >> >> /Names << /JavaScript << /Names [(a) << /S /JavaScript /JS (1) >>] >> >>",
                         page: "/Annots [6 0 R 7 0 R]", extra: { pdf in
            pdf.obj(6, "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /F 4 /Border [0 0 0] /A << /S /Launch /F (a.exe) /Next << /S /URI /URI (x) >> >>>>")
            pdf.obj(7, "<</Type /Annot /Subtype /Link /Rect [60 10 90 50] /F 4 /Border [0 0 0] /A << /S /URI /URI (http://example.com/) >>>>")
        })
        let result = try convert(file)
        let bytes = try clean(result)
        let document = try PdfDocument.open(bytes)
        XCTAssertFalse(PdfActions.hasJavaScript(document))
        XCTAssertTrue(result.changes.contains { $0.contains("actions or scripts") })
        let links = PdfLinks.read(document, document.pages[0])
        XCTAssertTrue(links.contains { $0.uri == "http://example.com/" })
    }

    func test_forbiddenAnnotationsGoAndTheOthersAreMadeVisibleWithAnAppearance() throws {
        let file = plain(page: "/Annots [6 0 R 7 0 R 8 0 R]", extra: { pdf in
            pdf.obj(6, "<</Type /Annot /Subtype /Sound /Rect [10 10 50 50] /F 4>>")
            pdf.obj(7, "<</Type /Annot /Subtype /Square /Rect [60 10 90 50] /F 2 /C [1 0 0]>>")
            pdf.obj(8, "<</Type /Annot /Subtype /Square /Rect [100 10 140 50] /C [0 0 1] /AP << /N 9 0 R /D 9 0 R >>>>")
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 RG 0 0 40 40 re S")
        })
        let bytes = try clean(try convert(file))
        let document = try PdfDocument.open(bytes)
        let annotations = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(annotations.count, 2)
        for annotation in annotations {
            XCTAssertTrue(annotation.hasAppearance)
            XCTAssertEqual(annotation.flags, .print)
        }
    }

    func test_aFormGetsItsAppearancesAndLosesNeedAppearancesAndXfa() throws {
        let file = plain(catalog: "/AcroForm << /Fields [6 0 R] /NeedAppearances true /DA (/Helv 12 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> /XFA [(a) 4 0 R] >>",
                         page: "/Annots [6 0 R]", extra: { pdf in
            pdf.obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (abc) /Rect [10 10 100 30] /F 4>>")
        })
        let bytes = try clean(try convert(file))
        let document = try PdfDocument.open(bytes)
        let form = PdfForm.read(document)
        XCTAssertFalse(form.needAppearances)
        XCTAssertFalse(document.hasXfa)
        XCTAssertEqual(form.find("name")?.value, "abc")
        let annotations = PdfAnnotations.read(document, document.pages[0])
        XCTAssertEqual(annotations.count, 1)
        XCTAssertTrue(annotations.first?.hasAppearance == true)
    }

    func test_lzwStreamsAreRewrittenWithFlate() throws {
        let lzw = PdfFilterEncoders.lzw(Array("BT /F1 12 Tf 20 100 Td (Hello world) Tj ET".utf8))
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "/Filter /LZWDecode", lzw)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
        let result = try convert(pdf.finish("/Root 1 0 R"))
        _ = try clean(result)
        XCTAssertTrue(result.changes.contains { $0.contains("LZW") })
    }

    func test_imageAndFormKeysThatAreNotAllowedAreRemoved() throws {
        let file = plain("q 10 0 0 10 0 0 cm /Im Do Q /Fm Do", resources: "/XObject << /Im 6 0 R /Fm 7 0 R >>", extra: { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Interpolate true /OPI << >> /Alternates []", [0])
            pdf.stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Ref << /F (x.pdf) /Page 0 >> /OPI << >>", "0 g 0 0 5 5 re f")
        })
        _ = try clean(try convert(file))
    }

    func test_layersAreKeptFromPart2AndDroppedInPart1() throws {
        let file = plain(catalog: "/OCProperties << /OCGs [6 0 R] /D << /Order [] /AS [<< /Event /View >>] >> >>", extra: { pdf in pdf.obj(6, "<</Type /OCG /Name (L)>>") })
        let kept = try PdfDocument.open(try clean(try convert(file)))
        XCTAssertEqual(PdfLayers.read(kept).layers.count, 1)
        let dropped = try PdfDocument.open(try clean(try convert(file, .a1b)))
        XCTAssertTrue(PdfLayers.read(dropped).layers.isEmpty)
    }

    func test_embeddedFilesGoInPart1AndGetTheirRelationshipInPart3() throws {
        let file = plain(catalog: "/Names << /EmbeddedFiles << /Names [(a.dat) 6 0 R] >> >>", extra: { pdf in
            pdf.obj(6, "<</Type /Filespec /F (a.dat) /EF << /F 7 0 R >>>>")
            pdf.stream(7, "/Type /EmbeddedFile", "hello")
        })
        _ = try clean(try convert(file, .a1b))
        let three = try PdfDocument.open(try clean(try convert(file, .a3b)))
        XCTAssertEqual(PdfAttachments.list(three).count, 1)
        let two = try PdfDocument.open(try clean(try convert(file)))
        XCTAssertTrue(PdfAttachments.list(two).isEmpty)
    }

    func test_infoAndXmpAgreeAndKeepTheTextAsWritten() throws {
        let title = "\u{DC}n\u{EF}code \"&\" <b>"
        let hex = "FEFF" + title.utf16.map { String(format: "%04X", UInt32($0)) }.joined()
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        pdf.obj(3, "<</Title <\(hex)> /Author (A & B) /Keywords (one, two) /Producer (Old Tool) /CreationDate (D:20200102030405+03'00')>>")
        let bytes = try clean(try convert(pdf.finish("/Root 1 0 R /Info 3 0 R")))
        let document = try PdfDocument.open(bytes)
        let meta = DocumentMetadata.read(document)
        XCTAssertEqual(meta.title, title)
        XCTAssertEqual(meta.author, "A & B")
        XCTAssertEqual(meta.producer, "Old Tool")
        XCTAssertEqual(meta.created, DateTimeOffset(2020, 1, 2, 3, 4, 5, offsetMinutes: 180))
        XCTAssertEqual(meta.modified, StandardsKit.date)
    }

    func test_part4KeepsOnlyTheDatesInInfo() throws {
        let file = plain(extra: { pdf in pdf.obj(6, "<</Title (T) /Author (A) /Producer (P)>>") }, trailer: "/Info 6 0 R")
        let document = try PdfDocument.open(try clean(try convert(file, .a4)))
        XCTAssertEqual(try XCTUnwrap(document.info).entries.map { $0.key }.sorted(), ["CreationDate", "ModDate"])
        XCTAssertEqual(DocumentMetadata.read(document).title, "T")
    }

    func test_aCmykFileWithoutACmykIntentIsReturnedWithWhatRemains() throws {
        let result = try convert(plain("0 0 0 1 k 0 0 50 50 re f"))
        XCTAssertNotNil(result.bytes)
        StandardsKit.assertHas(result.remaining) { $0.clause == "6.2.4.3" && $0.message.contains("DeviceCMYK") }
    }

    func test_aFileThatStillBreaksRulesDoesNotClaimTheLevel() throws {
        let result = try convert(plain("0 0 0 1 k 0 0 50 50 re f"))

        XCTAssertFalse(result.remaining.isEmpty)
        let document = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertNil(document.pdfAPart)
        XCTAssertTrue(result.changes.contains(PdfAText.notDeclared(.a2b)))
        XCTAssertEqual(PdfAValidator.validate(document, .a2b).issues.count, result.remaining.count)
        XCTAssertFalse(result.changes.contains(PdfAText.metadataWritten(.a2b)))
    }

    func test_aFileThatPassesNamesTheLevel() throws {
        let result = try convert(plain())

        let document = try PdfDocument.open(try clean(result))
        XCTAssertEqual(document.pdfAPart, 2)
        XCTAssertTrue(result.changes.contains(PdfAText.metadataWritten(.a2b)))
    }

    func test_anExistingIccOutputIntentIsKept() throws {
        let file = plain(catalog: "/OutputIntents [6 0 R]", extra: { pdf in
            pdf.obj(6, "<</Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (mine) /DestOutputProfile 7 0 R>>")
            pdf.stream(7, "/N 3", PdfASrgb.srgbProfile)
        })
        let result = try convert(file)
        let bytes = try clean(result)
        XCTAssertFalse(result.changes.contains { $0.contains("sRGB output intent") })
        let document = try PdfDocument.open(bytes)
        let intents = try XCTUnwrap(document.array(document.catalog, "OutputIntents"))
        let intent = try XCTUnwrap(document.resolve(intents.items[0]) as? PdfDictionary)
        XCTAssertEqual(document.name(intent, "S"), "GTS_PDFA1")
    }

    func test_anIntentProfileTheValidatorRefusesIsReplaced() throws {
        var scanner = PdfASrgb.srgbProfile
        scanner.replaceSubrange(12..<16, with: Array("scnr".utf8))
        let file = plain(catalog: "/OutputIntents [6 0 R]", extra: { pdf in
            pdf.obj(6, "<</Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (mine) /DestOutputProfile 7 0 R>>")
            pdf.stream(7, "/N 3", scanner)
        })
        let result = try convert(file)
        XCTAssertTrue(result.changes.contains { $0.contains("sRGB output intent") })
        XCTAssertFalse(try StandardsKit.clauses(try clean(result)).contains("6.2.3"))
    }

    func test_aForbiddenActionInANextArrayIsRemoved() throws {
        let file = plain(catalog: "/OpenAction << /S /URI /URI (x) /Next [<< /S /JavaScript /JS (1) >>] >>")
        let bytes = try clean(try convert(file))
        let document = try PdfDocument.open(bytes)
        XCTAssertFalse(PdfActions.hasJavaScript(document))
        XCTAssertFalse(try StandardsKit.clauses(bytes).contains("6.5.1"))
    }

    func test_theProfileIsTheOneFromLazyScan() {
        XCTAssertEqual(PdfASrgb.srgbProfile.count, 736)
        let hex = Sha256.hash(PdfASrgb.srgbProfile).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "af4efe28f6d311799865f325ba39184a2e978b113ca74124d60af7de22b105f4")
    }

    func test_theOutputOpensInPdfPigAndTheValidatorAgreesWithTheConversion() throws {
        let result = try convert(plain())
        _ = try clean(result)
        let again = try PdfDocument.open(try XCTUnwrap(result.bytes))
        XCTAssertTrue(PdfAValidator.validate(again, .a2b).issues.isEmpty)
    }
}
