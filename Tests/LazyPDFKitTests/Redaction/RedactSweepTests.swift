import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactSweepTests.cs: the same cases. Resources are built from what the new
// content names, and everything a redacted page reached that nothing painted reaches is emptied.

final class RedactSweepTests: XCTestCase {
    private let pixels = "ZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATAZQXPIXELSDATA123"
    private let imageEntries = "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8"
    private let place = "q 160 0 0 160 100 100 cm /Im1 Do Q"
    // The whole picture, so that no sample of it is left in the copy.
    private let whole = PdfRect(90, 90, 270, 270)

    private func cut(_ document: PdfDocument) throws -> RedactionResult { try PdfRedactor(document).apply([RedactionMark.fromRect(0, whole)]) }

    private func sortedKeys(_ dictionary: PdfDictionary?) -> [String] {
        (dictionary?.entries.map { $0.key } ?? []).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }

    func test_resourcesHoldOnlyWhatTheContentNames() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 300 300 Td (kept) Tj ET " + place,
            "/XObject <</Im1 7 0 R /Im2 8 0 R>> /ExtGState <</G 6 0 R>> /Foo <</X 8 0 R>> /ColorSpace <</DefaultRGB [/ICCBased 9 0 R] /Cs1 [/ICCBased 9 0 R]>> /ProcSet [/PDF /Text]") { pdf in
            pdf.obj(6, "<</Type /ExtGState /CA 0.5>>")
            pdf.stream(7, self.imageEntries, self.pixels)
            pdf.stream(8, self.imageEntries, self.pixels.replacingOccurrences(of: "PIXELS", with: "OTHERS"))
            pdf.stream(9, "/N 3", "ZQXPROFILE")
        }
        let result = try cut(document)
        let output = try RedactionKit.open(result)
        let resources = try XCTUnwrap(output.dict(output.pages[0].dictionary, "Resources"))
        XCTAssertEqual(sortedKeys(resources), ["ColorSpace", "Font", "ProcSet", "XObject"])
        XCTAssertEqual(sortedKeys(output.dict(resources, "Font")), ["F1"])
        XCTAssertEqual(sortedKeys(output.dict(resources, "ColorSpace")), ["DefaultRGB"])
        XCTAssertEqual(output.dict(resources, "XObject")?.entries.count, 1)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXOTHERS"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_copiedFormHoldsOnlyWhatItsNewContentNames() throws {
        let document = try RedactionKit.page("/Fm Do", "/XObject <</Fm 6 0 R /Im1 7 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Im1 7 0 R>>>>", "BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET")
            pdf.stream(7, self.imageEntries, self.pixels)
        }
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 200, 120))])
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXWORD"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_keysOfThePageAndAStructureElementCannotKeepTheCutPictureAlive() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in pdf.stream(6, self.imageEntries, self.pixels) }
        document.pages[0].dictionary["Thumb"] = PdfReference(6, 0)
        let deep = PdfDictionary()
        deep["Deep"] = PdfReference(6, 0)
        document.pages[0].dictionary["Keep"] = PdfArray([deep])
        let root = PdfDictionary()
        root["Type"] = PdfName("StructTreeRoot")
        root["K"] = PdfReference(6, 0)
        document.catalog["StructTreeRoot"] = try document.add(root)
        let result = try cut(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
        let output = try RedactionKit.open(result)
        XCTAssertEqual(output.pages.count, 1)
    }

    func test_holderNestedDeepInArraysCannotKeepTheCutPictureAlive() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in pdf.stream(6, self.imageEntries, self.pixels) }
        var held: PdfObject = PdfReference(6, 0)
        for _ in 0..<150 { held = PdfArray([held]) }
        document.pages[0].dictionary["Keep"] = held
        let result = try cut(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
    }

    func test_attachedFileOfThePageGoesWithIt() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET", "") { pdf in pdf.stream(6, "/Type /EmbeddedFile", "ZQXSOURCEFILE") }
        let files = PdfDictionary()
        files["F"] = PdfReference(6, 0)
        let spec = PdfDictionary()
        spec["Type"] = PdfName("Filespec")
        spec["EF"] = files
        document.pages[0].dictionary["AF"] = PdfArray([spec])
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXWORD"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSOURCEFILE"))
    }

    func test_streamOfAnObjectThatIsNotPaintedBecomesEmptyWhoeverNamesIt() throws {
        let document = try RedactionKit.page(place, "/XObject <</Im1 6 0 R>>") { pdf in pdf.stream(6, self.imageEntries, self.pixels) }
        document.catalog["Anywhere"] = PdfReference(6, 0)
        let result = try cut(document)
        let output = try RedactionKit.reopen(result.bytes)
        let held = try XCTUnwrap(output.resolve(output.catalog["Anywhere"]) as? PdfStream)
        XCTAssertTrue(try output.data(held).isEmpty)
        for e in held.dictionary.entries { XCTAssertEqual(e.key, "Length") }
    }

    func test_pageTreeAndPagesAreNeverEmptiedThroughADestination() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 100 Td (ZQXWORD) Tj ET")
        let link = try PdfAnnotationWriter(document).addLink(document.pages[0], PdfRect(300, 300, 400, 320), UriAction("https://example.com") as PdfAction)
        link.dictionary["Dest"] = PdfArray([document.pages[0].reference, PdfName("Fit")])
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXWORD"))
        let output = try RedactionKit.open(result)
        XCTAssertEqual(output.pages.count, 1)
        XCTAssertEqual(output.name(output.pages[0].dictionary, "Type"), "Page")
        XCTAssertEqual(PdfAnnotations.read(output, output.pages[0]).count, 1)
    }

    func test_objectPaintedByAPageWithoutMarksStaysAndOneItOnlyListsGoes() throws {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800] /Resources 8 0 R>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>")
        pdf.stream(5, "", place)
        pdf.stream(6, "", "q 100 0 0 100 300 300 cm /Im2 Do Q")
        pdf.obj(8, "<</XObject <</Im1 9 0 R /Im2 10 0 R>>>>")
        pdf.stream(9, imageEntries, pixels)
        pdf.stream(10, imageEntries, pixels.replacingOccurrences(of: "PIXELS", with: "KEPT"))
        let document = try PdfDocument.open(pdf.finish())
        let result = try cut(document)
        let output = try RedactionKit.open(result)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPIXELSDATA"))
        XCTAssertTrue(RedactionKit.holds(result.bytes, "ZQXKEPTDATA"))
        XCTAssertEqual(RedactionKit.images(output, 1).count, 1)
    }
}
