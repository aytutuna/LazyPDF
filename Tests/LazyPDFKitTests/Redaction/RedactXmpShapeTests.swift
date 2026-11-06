import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactXmpShapeTests.cs: the same cases. Page copies and ids in the forms XMP
// writers use besides the one Adobe tools write most: attributes, self-closed elements, other prefixes and encodings.

final class RedactXmpShapeTests: XCTestCase {
    private let head = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
        + "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:stRef='http://ns.adobe.com/xap/1.0/sType/ResourceRef#' xmlns:xmpGImg='http://ns.adobe.com/xap/1.0/g/img/' xmlns:zz='urn:zz'>"
    private let tail = "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"

    private func twoPages(_ more: (PdfDocument) throws -> Void) throws -> PdfDocument {
        let pdf = TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
        pdf.obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>")
        pdf.obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>")
        pdf.stream(5, "", "BT /F1 12 Tf 50 700 Td (other) Tj ET")
        pdf.stream(6, "", "BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET")
        pdf.obj(7, RedactionKit.helvetica)
        let document = try PdfDocument.open(pdf.finish())
        try more(document)
        return document
    }

    private func packet(_ document: PdfDocument, _ data: [UInt8]) throws -> PdfReference {
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        dictionary["Subtype"] = PdfName("XML")
        return try document.add(PdfStream(dictionary, data: data))
    }

    private func redact(_ document: PdfDocument) throws -> RedactionResult {
        try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 1, "ZQXMARKER"))
    }

    private func wrap(_ body: String) -> String { head + body + tail }

    func test_pageImageHeldInAttributesIsDropped() throws {
        let xmp = wrap("<zz:PageImages><rdf:Alt><rdf:li xmpGImg:format=\"JPEG\" xmpGImg:image=\"ZQXPAGEIMAGE\"/></rdf:Alt></zz:PageImages>")
        let document = try twoPages { d in d.catalog["Metadata"] = try self.packet(d, Array(xmp.utf8)) }
        XCTAssertFalse(RedactionKit.holds(try redact(document).bytes, "ZQXPAGEIMAGE"))
    }

    func test_selfClosedDerivedFromAndOtherPrefixedIdsAreDropped() throws {
        let xmp = wrap("<xmpMM:DerivedFrom stRef:instanceID=\"ZQXIID\" stRef:documentID=\"ZQXDID\"/><xapMM:DocumentID>ZQXOLDID</xapMM:DocumentID><mm:InstanceID xmlns:mm='http://ns.adobe.com/xap/1.0/mm/'>ZQXREBOUND</mm:InstanceID>")
        let document = try twoPages { d in d.catalog["Metadata"] = try self.packet(d, Array(xmp.utf8)) }
        let result = try redact(document)
        for word in ["ZQXIID", "ZQXDID", "ZQXOLDID", "ZQXREBOUND"] { XCTAssertFalse(RedactionKit.holds(result.bytes, word), word) }
    }

    func test_utf16PacketWithTheMarkInsideTheWrapperIsRead() throws {
        for bigEndian in [true, false] {
            let xmp = wrap("<xmp:Thumbnails xmlns:xmp='http://ns.adobe.com/xap/1.0/'><rdf:Alt><rdf:li><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>")
                .replacingOccurrences(of: "begin=''", with: "begin='\u{FEFF}'")
            let data = xmp.utf16.flatMap { bigEndian ? [UInt8($0 >> 8), UInt8($0 & 0xFF)] : [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let document = try twoPages { d in d.catalog["Metadata"] = try self.packet(d, data) }
            XCTAssertFalse(RedactionKit.holds(try redact(document).bytes, "ZQXPAGEIMAGE"))
        }
    }

    func test_packetOfAPageHeldOnlyBySubtypeIsVisited() throws {
        let xmp = wrap("<xmp:Thumbnails xmlns:xmp='http://ns.adobe.com/xap/1.0/'><rdf:Alt><rdf:li><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>")
        let document = try twoPages { d in
            let dictionary = PdfDictionary()
            dictionary["Subtype"] = PdfName("XML")
            d.pages[0].dictionary["Metadata"] = try d.add(PdfStream(dictionary, data: Array(xmp.utf8)))
        }
        XCTAssertFalse(RedactionKit.holds(try redact(document).bytes, "ZQXPAGEIMAGE"))
    }

    func test_packetNamedOnlyByAMetadataKeyIsVisited() throws {
        let xmp = wrap("<xmp:Thumbnails xmlns:xmp='http://ns.adobe.com/xap/1.0/'><rdf:Alt><rdf:li><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>")
        let document = try twoPages { d in d.pages[0].dictionary["Metadata"] = try d.add(PdfStream(PdfDictionary(), data: Array(xmp.utf8))) }
        XCTAssertFalse(RedactionKit.holds(try redact(document).bytes, "ZQXPAGEIMAGE"))
    }
}
