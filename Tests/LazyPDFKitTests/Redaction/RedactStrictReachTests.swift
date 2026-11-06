import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactStrictReachTests.cs: the same cases. What stays of the file after a
// redaction is what the pages paint, found by the keys that paint, and not whatever an object names.

final class RedactStrictReachTests: XCTestCase {
    private let pixels = String(String(repeating: "ZQXPIXELS", count: 8).prefix(64))
    private let entries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let place = "q 200 0 0 200 100 100 cm /Im1 Do Q "
    private let word = "BT /F1 12 Tf 100 100 Td (ZQXSECRET) Tj ET"
    private let overImage = RedactionMark.fromRect(0, PdfRect(100, 100, 300, 300))

    private func makeFile(_ content: String, _ resources: String = "", _ more: ((TestPdf) -> Void)? = nil, catalog: String = "", page: String = "", node: String = "") -> [UInt8] {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalog)>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] \(node)>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>> \(resources)>> \(page)>>")
        pdf.stream(4, "", content)
        pdf.obj(5, RedactionKit.helvetica)
        more?(pdf)
        return pdf.finish()
    }

    private func redact(_ file: [UInt8], _ marks: RedactionMark...) throws -> RedactionResult {
        try RedactionKit.apply(try PdfDocument.open(file), marks)
    }

    private func assertPixelsGone(_ result: RedactionResult) {
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELS"))
    }

    func test_keyOfAUsedStateDoesNotKeepThePictureItNames() throws {
        let file = makeFile("/G0 gs " + place, "/ExtGState <</G0 6 0 R>> /XObject <</Im1 7 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /CA 1 /Keep 7 0 R>>")
            pdf.stream(7, self.entries, self.pixels)
        }
        assertPixelsGone(try redact(file, overImage))
    }

    func test_arrayOfStreamsUnderAnyKeyDoesNotKeepThem() throws {
        let file = makeFile(place, "/XObject <</Im1 7 0 R>>") { pdf in
            pdf.obj(6, "<</Type /ExtGState /Keep [7 0 R]>>")
            pdf.stream(7, self.entries + " /Alternates [<</Image 8 0 R>>]", self.pixels)
            pdf.stream(8, self.entries, self.pixels)
        }
        assertPixelsGone(try redact(file, overImage))
    }

    func test_resourceListTypedAsAPageIsStillSweptAndSoIsWhatTheCatalogNamesBesides() throws {
        let file = makeFile(place, "/XObject 8 0 R", { pdf in
            pdf.stream(7, self.entries, self.pixels)
            pdf.obj(8, "<</Type /Page /Im1 7 0 R>>")
        }, catalog: "/Keep 7 0 R")
        assertPixelsGone(try redact(file, overImage))
    }

    func test_appearanceOfAKeptAnnotationDoesNotKeepThePageResourcesItListsOnly() throws {
        let file = makeFile(place + word, "/XObject <</Im1 7 0 R>>", { pdf in
            pdf.stream(7, self.entries, self.pixels)
            pdf.obj(9, "<</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>")
            pdf.obj(11, "<</Type /Annot /Subtype /Stamp /Rect [400 400 500 500] /AP <</N 10 0 R>>>>")
            pdf.stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources 9 0 R", "0 0 10 10 re f")
        }, page: "/Annots [11 0 R]")
        assertPixelsGone(try redact(file, overImage))
    }

    func test_resourcesInTheTreeAreFoundWithoutAParentLink() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>>>")
        pdf.obj(3, "<</Type /Page /Contents 4 0 R>>")
        pdf.stream(4, "", place)
        pdf.obj(5, RedactionKit.helvetica)
        pdf.stream(7, entries, pixels)
        assertPixelsGone(try redact(pdf.finish(), overImage))
    }

    func test_pageTreeWithoutTypesIsLeftWhole() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "", word)
        pdf.obj(5, RedactionKit.helvetica)
        let result = try redact(pdf.finish(), RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120)))
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertEqual(output.pages.count, 1)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECRET"))
    }

    func test_unmarkedPageThatCannotBeFollowedIsReportedAndKeepsOnlyWhatItLists() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 8 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources 9 0 R>>")
        pdf.stream(4, "", place + word)
        pdf.obj(5, RedactionKit.helvetica)
        pdf.obj(8, "<</Type /Page /Parent 2 0 R /Contents 10 0 R /Resources 9 0 R /Keep 4 0 R>>")
        pdf.obj(9, "<</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>")
        pdf.stream(10, "", "Q")
        pdf.stream(7, entries, pixels)
        let result = try redact(pdf.finish(), overImage)
        XCTAssertTrue(result.verification.problems.contains(RedactionText.notFollowed(1)))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECRET"))
    }

    func test_boxesAndTurnThatAreObjectsOfTheirOwnSurviveOnEveryPageThatSharesThem() throws {
        for flatten in [false, true] {
            let pdf = TestPdf()
            pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            pdf.obj(2, "<</Type /Pages /Kids [3 0 R 8 0 R] /Count 2>>")
            pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /MediaBox 10 0 R /Rotate 11 0 R>>")
            pdf.stream(4, "", (flatten ? "BX EX " : "") + word)
            pdf.obj(5, RedactionKit.helvetica)
            pdf.obj(8, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>> /MediaBox 10 0 R /Rotate 11 0 R>>")
            pdf.obj(10, "[0 0 400 900]")
            pdf.obj(11, "90")
            let result = try redact(pdf.finish(), RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120)))
            let output = try RedactionKit.reopen(result.bytes)
            for page in output.pages {
                XCTAssertEqual(page.mediaBox.width, 400)
                XCTAssertEqual(page.rotate, 90)
            }
        }
    }

    func test_pictureShownAgainWhereNoMarkIsMakesThePagePicture() throws {
        let document = try PdfDocument.open(makeFile(place + "q 1 0 0 1 5000 0 cm 200 0 0 200 100 100 cm /Im1 Do Q", "/XObject <</Im1 7 0 R>>") { pdf in
            pdf.stream(7, self.entries, self.pixels)
        })
        try RedactionKit.assertFlattened(document, [overImage], "ZQXPIXELS")
    }

    func test_pictureShownTwiceUnderTheMarksIsCutBothTimes() throws {
        let document = try PdfDocument.open(makeFile(place + place, "/XObject <</Im1 7 0 R>>") { pdf in pdf.stream(7, self.entries, self.pixels) })
        let result = try PdfRedactor(document).apply([overImage])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertEqual(result.report.images, 2)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELS"))
    }

    func test_formWithoutResourcesKeepsTheNamesItTakesFromThePage() throws {
        let document = try PdfDocument.open(makeFile(word + " /Fm Do", "/XObject <</Fm 6 0 R /Im1 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800]", "q 100 0 0 100 400 400 cm /Im1 Do Q")
            pdf.stream(7, self.entries, self.pixels)
        })
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120))])
        XCTAssertTrue(result.report.flattened.isEmpty)
        let output = try RedactionKit.open(result)
        let list = try XCTUnwrap(output.dict(output.dict(output.pages[0].dictionary, "Resources"), "XObject"))
        XCTAssertTrue(list.containsKey("Fm") && list.containsKey("Im1"))
        XCTAssertEqual(RedactionKit.images(output).count, 1)
    }

    func test_fontChosenAgainInsideASavedStateIsStillTheOneAfterIt() throws {
        let document = try ContentTestPdf.page("BT /F1 12 Tf 100 600 Td (ZQXSECRET) Tj ET /F1 12 Tf q /F2 10 Tf Q BT 100 300 Td (KEEPB) Tj ET",
                                               "/Font <</F1 5 0 R /F2 5 0 R>>", [RedactionKit.helvetica])
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXSECRET"))
        let output = try RedactionKit.open(result)
        XCTAssertEqual(RedactionKit.text(output), "KEEPB")
    }

    func test_catalogKeysOfTheLayersDoNotKeepWhatTheyNameBesides() throws {
        let file = makeFile(place, "/XObject <</Im1 7 0 R>>", { pdf in pdf.stream(7, self.entries, self.pixels) },
                            catalog: "/OCProperties <</OCGs [] /D <<>> /Keep [7 0 R]>> /OutputIntents [<</S /GTS_PDFA1 /Extra 7 0 R>>]")
        assertPixelsGone(try redact(file, overImage))
    }

    func test_visibleLayerKeepsThePageAsText() throws {
        let file = makeFile("/OC /MC0 BDC " + word + " EMC", "/Properties <</MC0 6 0 R>>", { pdf in pdf.obj(6, "<</Type /OCG /Name (Layer)>>") },
                            catalog: "/OCProperties <</OCGs [6 0 R] /D <</ON [6 0 R]>>>>")
        let document = try PdfDocument.open(file)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120))])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECRET"))
    }

    func test_hiddenLayerMakesThePagePicture() throws {
        let file = makeFile("/OC /MC0 BDC " + word + " EMC", "/Properties <</MC0 6 0 R>>", { pdf in pdf.obj(6, "<</Type /OCG /Name (Layer)>>") },
                            catalog: "/OCProperties <</OCGs [6 0 R] /D <</OFF [6 0 R]>>>>")
        let document = try PdfDocument.open(file)
        try RedactionKit.assertFlattened(document, [RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120))], "ZQXSECRET")
    }

    func test_fontDescriptorWithWildMetricsStillCutsTheTextUnderTheMark() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>")
        pdf.stream(4, "", word)
        pdf.obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FontDescriptor 6 0 R>>")
        pdf.obj(6, "<</Type /FontDescriptor /FontName /Helvetica /Flags 32 /Ascent -5000 /Descent -6000 /ItalicAngle 0 /CapHeight 700 /StemV 80 /FontBBox [-166 -225 1000 931]>>")
        let document = try PdfDocument.open(pdf.finish())
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120))])
        XCTAssertTrue(result.report.flattened.isEmpty)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECRET"))
    }

    func test_strokeInAStretchedSpaceIsFoundWhereItIsPainted() throws {
        let document = try PdfDocument.open(makeFile("q 1000 0 0 1 0 0 cm 1 w 0.15 100 m 0.15 700 l S Q"))
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(400, 300, 500, 400))])
        XCTAssertEqual(result.report.paths, 1)
    }

    func test_descriptionBesideRemovedTextDoesNotStay() throws {
        for (before, after) in [("/Note <</ActualText (ZQXDESC)>> DP ", ""), ("/Span <</Title (ZQXDESC)>> BDC ", " EMC")] {
            let document = try PdfDocument.open(makeFile(before + word + after))
            let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120))])
            XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXDESC"))
        }
    }

    func test_noteWithNoExtentInsideTheMarkGoesWithIt() throws {
        let document = try PdfDocument.open(makeFile(word))
        let note = try PdfAnnotationWriter(document).addNote(document.pages[0], PdfRect(150, 100, 160, 110), AnnotationInfo(author: "Reviewer", contents: "ZQXNOTE"))
        note.dictionary["Rect"] = PdfRect(150, 100, 150, 100).toArray()
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 300, 120))])
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXNOTE"))
    }

    func test_markWrittenInTheOrderOfTheSpecificationIsFilledWhole() throws {
        let document = try PdfDocument.open(makeFile("BX EX " + word))
        // Upper right, upper left, lower right, lower left: the corners cross unless they are put in order.
        let mark = RedactionMark(0, [TextQuad(300, 300, 100, 300, 300, 100, 100, 100)])
        let result = try RedactionKit.apply(document, [mark])
        let output = try RedactionKit.reopen(result.bytes)
        let images = RedactionKit.images(output)
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first)
        let samples = try output.data(try XCTUnwrap(image.stream))
        let scale = Double(image.width) / 600.0
        for (x, y) in [(110.0, 200.0), (290.0, 200.0), (200.0, 120.0), (200.0, 280.0)] {
            let i = (Int((800 - y) * scale) * image.width + Int(x * scale)) * 3
            XCTAssertEqual(Array(samples[i..<(i + 3)]), [0, 0, 0])
        }
    }

    func test_markFarBeyondThePageStillFillsThePicture() throws {
        let document = try PdfDocument.open(makeFile("BX EX " + word))
        let result = try RedactionKit.apply(document, [RedactionMark.fromRect(0, PdfRect(-1e12, -1e12, 1e12, 1e12))])
        let output = try RedactionKit.reopen(result.bytes)
        let images = RedactionKit.images(output)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(Array(try output.data(try XCTUnwrap(images[0].stream)).prefix(3)), [0, 0, 0])
    }

    func test_descriptionDeepInTheTagTreeDoesNotStay() throws {
        let document = try PdfDocument.open(makeFile(word))
        let leaf = PdfDictionary()
        leaf["S"] = PdfName("Figure")
        leaf["Alt"] = PdfString(bytes: Array("ZQXPORTRAIT".utf8), isHex: false)
        var top = leaf
        for _ in 0..<70 {
            let next = PdfDictionary()
            next["S"] = PdfName("Div")
            next["K"] = top
            top = next
        }
        let root = PdfDictionary()
        root["Type"] = PdfName("StructTreeRoot")
        root["K"] = top
        document.catalog["StructTreeRoot"] = try document.add(root)
        try RedactionStructure.prune(document, [:], RedactionObjects.Identities(), [])
        XCTAssertFalse(leaf.containsKey("Alt"))
    }

    func test_wordInAZipAttachedWithoutATypeIsFound() throws {
        let file = makeFile("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", { pdf in
            pdf.stream(6, "", RedactionKit.gzip(Latin1.bytes("the ZQXCYCLE word")))
            pdf.obj(7, "<</Type /Filespec /F (a.gz) /EF <</F 6 0 R>>>>")
        }, catalog: "/Names <</EmbeddedFiles <</Names [(a) 7 0 R]>>>>")
        RedactionKit.assertOneProblem(PdfRedactor.verify(file, [], ["ZQXCYCLE"]).problems, attached: true, found: true)
    }

    func test_containerOfAnotherFormatIsNotCalledClean() throws {
        let file = makeFile("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", { pdf in
            pdf.stream(6, "", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4, 1, 2, 3])
            pdf.obj(7, "<</Type /Filespec /F (a.7z) /EF <</F 6 0 R>>>>")
        }, catalog: "/Names <</EmbeddedFiles <</Names [(a) 7 0 R]>>>>")
        XCTAssertTrue(PdfRedactor.verify(file, [], ["ZQXCYCLE"]).problems.contains(RedactionText.notChecked(RedactionText.attachedFile(6))))
    }

    func test_streamThatCannotBeDecodedIsNotCalledClean() throws {
        let file = makeFile("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", { pdf in pdf.stream(6, "/Filter /BogusDecode", "nothing to see") }, catalog: "/Keep 6 0 R")
        XCTAssertTrue(PdfRedactor.verify(file, [], ["ZQXCYCLE"]).problems.contains(RedactionText.notChecked("object 6")))
    }

    func test_programKeysOutsideAFontDoNotHideTheWord() throws {
        for catalog in ["/Keep <</FontFile 6 0 R>>", "/Keep <</ToUnicode 6 0 R>>"] {
            let file = makeFile("BT /F1 12 Tf 100 100 Td (hello) Tj ET", "", { pdf in pdf.stream(6, "", "the ZQXCYCLE word") }, catalog: catalog)
            XCTAssertTrue(PdfRedactor.verify(file, [], ["ZQXCYCLE"]).problems.contains(RedactionText.stillInFile("object 6")), catalog)
        }
    }

    func test_charSetOutsideAFontDescriptorDoesNotHideTheWord() throws {
        let file = makeFile("BT /F1 12 Tf 100 100 Td (hello) Tj ET", catalog: "/Keep <</CharSet (ZQXCYCLE is here)>>")
        XCTAssertFalse(PdfRedactor.verify(file, [], ["ZQXCYCLE"]).problems.isEmpty)
    }
}
