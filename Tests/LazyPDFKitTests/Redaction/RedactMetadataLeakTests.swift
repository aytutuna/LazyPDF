import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactMetadataLeakTests.cs: the same cases.

final class RedactMetadataLeakTests: XCTestCase {
    private func twoPages(_ more: ((PdfDocument) throws -> Void)? = nil) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>> /PieceInfo <</Illustrator <</Private <</AIPrivateData1 (ZQXPAGEPIECE)>>>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.stream(5, "", "BT /F1 12 Tf 50 700 Td (other) Tj ET")
        pdf.stream(6, "", "BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET")
        pdf.obj(7, RedactionKit.helvetica)
        let document = try PdfDocument.open(pdf.finish())
        try more?(document)
        return document
    }

    private func setPacket(_ document: PdfDocument, _ data: [UInt8]) throws {
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        dictionary["Subtype"] = PdfName("XML")
        document.catalog["Metadata"] = try document.add(PdfStream(dictionary, data: data))
    }

    private func redact(_ document: PdfDocument, _ change: Bool = false) throws -> RedactionResult {
        var options = RedactionOptions()
        options.changeMetadata = change
        return try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 1, "ZQXMARKER"), options)
    }

    func test_privateDataOfAPageNobodyMarkedIsDropped() throws {
        let document = try twoPages()
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPAGEPIECE"))
    }

    func test_pageImagesAndDocumentIdsInOtherXmpWrappersAreDropped() throws {
        let xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:xmp='http://ns.adobe.com/xap/1.0/' xmlns:xmpGImg='http://ns.adobe.com/xap/1.0/g/img/' xmpMM:OriginalDocumentID='ZQXORIG'>"
            + "<xmpMM:DocumentID>ZQXLINKID</xmpMM:DocumentID><xmpMM:InstanceID>ZQXINSTANCE</xmpMM:InstanceID>"
            + "<xmp:PageInfo><rdf:Alt><rdf:li rdf:parseType='Resource'><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:PageInfo>"
            + "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"
        let document = try twoPages { try self.setPacket($0, Array(xmp.utf8)) }
        let result = try redact(document)
        for word in ["ZQXPAGEIMAGE", "ZQXLINKID", "ZQXINSTANCE", "ZQXORIG"] { XCTAssertFalse(RedactionKit.holds(result.bytes, word), word) }
    }

    func test_packetInUtf16IsSearchedToo() throws {
        let xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title><rdf:Alt><rdf:li xml:lang='x-default'>about ZQXMARKER</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"
        let wide: [UInt8] = [0xFF, 0xFE] + xmp.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let document = try twoPages { try self.setPacket($0, wide) }
        let result = try redact(document, true)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMARKER"))
        XCTAssertTrue(result.report.findings.contains { $0.where == "The XMP metadata" })
    }

    func test_packetThatCannotBeReadIsDropped() throws {
        let document = try twoPages { try self.setPacket($0, Latin1.bytes("ZQXBROKENPACKET")) }
        let packet = try XCTUnwrap(document.resolve(document.catalog["Metadata"]) as? PdfStream)
        packet.dictionary["Filter"] = PdfName("FlateDecode")
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXBROKENPACKET"))
    }

    func test_indirectStringIsReplacedWhenMetadataIsChanged() throws {
        let document = try twoPages { d in
            let text = try d.add(PdfText.toObject("about ZQXMARKER here"))
            let note = PdfDictionary()
            note["Type"] = PdfName("Annot")
            note["Subtype"] = PdfName("Text")
            note["Rect"] = PdfArray([PdfNumber(400), PdfNumber(400), PdfNumber(420), PdfNumber(420)])
            note["Contents"] = text
            d.pages[1].dictionary["Annots"] = PdfArray([try d.add(note)])
        }
        let result = try redact(document, true)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMARKER"))
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }
}
