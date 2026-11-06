import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactVerifyTests.cs: the same cases.

final class RedactVerifyTests: XCTestCase {
    func test_textStillInsideAMarkIsFound() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (alphabet here) Tj ET")
        let marks = try RedactionKit.marksOf(document, 0, "alphabet")
        let check = PdfRedactor.verify(try document.saveRewrite(), marks, [])
        XCTAssertFalse(check.isClean)
        XCTAssertEqual(check.problems.count, 1)
        XCTAssertTrue(check.problems[0].contains("page 1"))
        XCTAssertFalse(check.problems[0].contains("alphabet"))
    }

    func test_overlayTextInsideTheMarkIsNotAProblem() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (hidden) Tj ET")
        let marks = try RedactionKit.marksOf(document, 0, "hidden").map { m -> RedactionMark in
            var covered = m
            covered.overlayText = "REDACTED"
            return covered
        }
        let result = try PdfRedactor(document).apply(marks)
        XCTAssertTrue(result.verification.isClean)
        let again = try PdfDocument.open(result.bytes)
        XCTAssertFalse(PdfRedactor.verify(result.bytes, try RedactionKit.marksOf(again, 0, "REDACTED"), [], []).isClean)
    }

    func test_packetIsSearchedByItsTextAndByItsBytes() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (plain) Tj ET")
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        dictionary["Subtype"] = PdfName("XML")
        let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF><rdf:Description><xmpG:mode>RGB</xmpG:mode><dc:title>a &#103;izli b</dc:title></rdf:Description></rdf:RDF></x:xmpmeta>"
        document.catalog["Metadata"] = try document.add(PdfStream(dictionary, data: Array(xmp.utf8)))
        let bytes = try document.saveRewrite()
        // A name holds a word as much as a text does, and the bytes are searched besides the text.
        XCTAssertFalse(PdfRedactor.verify(bytes, [], ["mode"]).isClean)
        XCTAssertTrue(PdfRedactor.verify(bytes, [], ["absent"]).isClean)
        XCTAssertFalse(PdfRedactor.verify(bytes, [], ["gizli"]).isClean)
    }

    func test_removedStringsAreLookedForInEveryObjectAndStream() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (plain) Tj ET")
        let info = PdfDictionary()
        info["Subject"] = PdfText.toObject("about Gizli Belge")
        document.trailer["Info"] = try document.add(info)
        document.catalog["Names"] = try document.add(PdfDictionary())
        let dictionary = PdfDictionary()
        dictionary["Filter"] = PdfName("FlateDecode")
        let text = "xx Dosya Ad\u{131} Gizli Belge yy"
        let wide = text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        document.catalog["Extra"] = try document.add(PdfStream(dictionary, data: PdfFilterEncoders.flate(wide)))
        let check = PdfRedactor.verify(try document.saveRewrite(), [], ["Gizli Belge", "absent text"])
        XCTAssertEqual(check.problems.count, 2)
        for p in check.problems { XCTAssertFalse(p.contains("Gizli")) }
    }

    func test_fontProgramsAndCodeMapsAreNotSearched() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 100 700 Td (plain) Tj ET")
        let program = try document.add(PdfStream(PdfDictionary(), data: Latin1.bytes("glyf table with leaked words in a name record")))
        let map = try document.add(PdfStream(PdfDictionary(), data: Latin1.bytes("%%BeginResource: CMap (leaked words)")))
        let descriptor = PdfDictionary()
        descriptor["Type"] = PdfName("FontDescriptor")
        descriptor["FontFile2"] = program
        descriptor["ToUnicode"] = map
        document.catalog["Extra"] = try document.add(descriptor)
        XCTAssertTrue(PdfRedactor.verify(try document.saveRewrite(), [], ["leaked words"]).isClean)
    }

    func test_contentOperandsOtherThanTheShownTextAreSearchedToo() throws {
        let document = try RedactionKit.page("/Span <</ActualText (leaked words)>> BDC BT /F1 12 Tf 100 700 Td (leaked words) Tj ET EMC")
        let check = PdfRedactor.verify(try document.saveRewrite(), [], ["leaked words"])
        XCTAssertEqual(check.problems.count, 1)
    }

    func test_aBrokenOutputIsReported() {
        let check = PdfRedactor.verify([1, 2, 3], [], [])
        XCTAssertEqual(check.problems, [RedactionText.doesNotOpen])
    }
}
