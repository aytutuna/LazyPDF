import XCTest
@testable import LazyPDFKit

// No C# twin: cases found by reviewing the Swift port against the C#, where the C# is right and the port was not. Each one
// states what the .NET type does.

final class RedactReviewTests: XCTestCase {
    private func tagged(_ mcid: Int) throws -> (document: PdfDocument, element: PdfDictionary) {
        let document = try RedactionKit.page("/Figure <</MCID 0>> BDC q 100 0 0 100 100 100 cm /Im1 Do Q EMC", "/XObject <</Im1 6 0 R>>") { pdf in
            pdf.stream(6, "/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", [UInt8](repeating: 9, count: 64))
        }
        let root = PdfDictionary()
        root["Type"] = PdfName("StructTreeRoot")
        let figure = PdfDictionary()
        let rootRef = try document.add(root)
        let figureRef = try document.add(figure)
        root["K"] = PdfArray([figureRef])
        figure["Type"] = PdfName("StructElem")
        figure["S"] = PdfName("Figure")
        figure["P"] = rootRef
        let item = PdfDictionary()
        item["Type"] = PdfName("MCR")
        item["Pg"] = document.pages[0].reference
        item["MCID"] = PdfNumber(mcid)
        figure["K"] = item
        figure["Alt"] = PdfText.toObject("Photo of passport 123")
        document.catalog["StructTreeRoot"] = rootRef
        return (document, figure)
    }

    // (int)long keeps the low 32 bits: 4294967296 is 0, the number of the sequence.
    func test_contentItemNumberIsCutToTheLow32BitsAsTheCastDoes() throws {
        let (document, _) = try tagged(4_294_967_296)
        let result = try PdfRedactor(document).apply([RedactionMark.fromRect(0, PdfRect(90, 90, 210, 210))])
        XCTAssertEqual(result.report.images, 1)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "Photo of passport"))
    }

    // XmlTextWriter.WriteComment refuses a comment with two hyphens in it or ending in one: the packet is emptied and reported.
    func test_commentTheXmlWriterRefusesEmptiesThePacket() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET")
        let xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description><!-- ZQXMARKER - --></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        dictionary["Subtype"] = PdfName("XML")
        document.catalog["Metadata"] = try document.add(PdfStream(dictionary, data: Array(xmp.utf8)))
        var options = RedactionOptions()
        options.changeMetadata = true
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"), options)
        XCTAssertTrue(result.report.findings.contains { $0.where == RedactionText.xmpUnreadable })
        XCTAssertFalse(RedactionKit.holds(result.bytes, "redacted"))
    }

    // OrdinalIgnoreCase folds by the simple upper case: U+1F80 and U+1F88 are the same letter, and so are the two cases of an
    // Adlam letter outside the BMP.
    func test_metadataIsFoundWhateverTheCaseOfLettersTheFullMappingLengthens() throws {
        for (needle, title) in [("\u{1F80}x", "\u{1F88}X"), ("\u{1FB3}x", "\u{1FBC}X"), ("\u{1E922}\u{1E922}", "\u{1E900}\u{1E900}")] {
            let document = try RedactionKit.page("BT ET")
            let info = PdfDictionary()
            info["Title"] = PdfText.toObject("about " + title)
            document.trailer["Info"] = try document.add(info)
            let findings = try RedactionMetadata.scan(document, [needle], true)
            XCTAssertTrue(findings.contains { $0.where == "The document information" && $0.changed }, needle)
            let text = PdfText.decode(try XCTUnwrap(document.info?["Title"] as? PdfString).bytes)
            XCTAssertEqual(text, "about [redacted]", needle)
        }
    }

    // Enumerable.Max of doubles skips a NaN and is NaN only when nothing else is there; Min is NaN when one is.
    func test_maximumSkipsNaNAndMinimumDoesNot() {
        XCTAssertEqual(Geometry.maximum([.nan, 3, 2]), 3)
        XCTAssertEqual(Geometry.maximum([1, .nan, 7]), 7)
        XCTAssertTrue(Geometry.maximum([.nan, .nan]).isNaN)
        XCTAssertTrue(Geometry.minimum([4, .nan, 2]).isNaN)
        XCTAssertEqual(Geometry.minimum([4, 3, 2]), 2)
    }

}
