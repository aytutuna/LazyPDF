import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Document/DocumentFactsTests.cs: the same cases, and one more for the XMP scan
// that XmlReader does not need.

final class DocumentFactsTests: XCTestCase {
    private func open(_ catalogEntries: String, _ extra: TestPdf? = nil, trailer: String = "/Root 1 0 R") throws -> PdfDocument {
        let pdf = extra ?? TestPdf()
        pdf.obj(1, "<</Type /Catalog /Pages 2 0 R \(catalogEntries)>>")
        pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
        return try PdfDocument.open(pdf.finish(trailer))
    }

    func test_plainFileHasNoFlags() throws {
        let document = try PdfDocument.open(TestPdf.simple())
        XCTAssertFalse(document.isSigned)
        XCTAssertFalse(document.isCertified)
        XCTAssertFalse(document.hasXfa)
        XCTAssertFalse(document.isTagged)
        XCTAssertFalse(document.isLinearized)
        XCTAssertFalse(document.isEncrypted)
        XCTAssertNil(document.pdfAPart)
        XCTAssertNil(document.pdfAConformance)
        XCTAssertNil(document.info)
        XCTAssertTrue(document.id.isEmpty)
    }

    func test_signatureFlagsAndPermissions() throws {
        XCTAssertTrue(try open("/AcroForm <</SigFlags 3 /Fields []>>").isSigned)
        XCTAssertFalse(try open("/AcroForm <</SigFlags 2>>").isSigned)
        XCTAssertTrue(try open("/Perms <</UR3 << >> >>").isSigned)
        let certified = try open("/Perms <</DocMDP 9 0 R>>", TestPdf().obj(9, "<</Type /Sig>>"))
        XCTAssertTrue(certified.isSigned)
        XCTAssertTrue(certified.isCertified)
        XCTAssertFalse(try open("/Perms <</UR3 << >> >>").isCertified)
    }

    func test_xfaAndTags() throws {
        XCTAssertTrue(try open("/AcroForm <</XFA [(preamble) 7 0 R]>>").hasXfa)
        XCTAssertFalse(try open("/AcroForm <</Fields []>>").hasXfa)
        XCTAssertTrue(try open("/MarkInfo <</Marked true>>").isTagged)
        XCTAssertFalse(try open("/MarkInfo <</Marked false>>").isTagged)
    }

    func test_linearizedFileSaysSoInItsFirstObject() throws {
        func build(_ length: String) -> [UInt8] {
            let pdf = TestPdf("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n").obj(7, "<</Linearized 1 /L \(length) /N 1>>")
            pdf.obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            pdf.obj(2, "<</Type /Pages /Kids [] /Count 0>>")
            return pdf.finish()
        }
        let size = build("000").count
        XCTAssertTrue(try PdfDocument.open(build(String(size))).isLinearized)
        // A length that is not the file's means something was added or cut after.
        XCTAssertFalse(try PdfDocument.open(build(String(size + 1))).isLinearized)
    }

    func test_pdfAIsReadFromTheMetadata() throws {
        let xmp = "<?xpacket begin='' id='W5M0'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description rdf:about='' xmlns:pdfaid='http://www.aiim.org/pdfa/ns/id/' pdfaid:part='2' pdfaid:conformance='u'/></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"
        let document = try open("/Metadata 9 0 R", TestPdf().stream(9, "/Type /Metadata /Subtype /XML", xmp))
        XCTAssertEqual(document.pdfAPart, 2)
        XCTAssertEqual(document.pdfAConformance, "U")
    }

    func test_pdfAElementsAndBrokenMetadata() {
        let xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/' xmlns:pdfaid='http://www.aiim.org/pdfa/ns/id/'><pdfaid:part>1</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></x:xmpmeta>"
        let read = PdfDocument.readPdfAId(Array(xmp.utf8))
        XCTAssertEqual(read.part, 1)
        XCTAssertEqual(read.conformance, "B")
        let broken = PdfDocument.readPdfAId(Array("<x:xmpmeta><broken".utf8))
        XCTAssertNil(broken.part)
        XCTAssertNil(broken.conformance)
        let bomb = "<!DOCTYPE x [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><x:xmpmeta xmlns:x='adobe:ns:meta/'>&b;</x:xmpmeta>"
        let refused = PdfDocument.readPdfAId(Array(bomb.utf8))
        XCTAssertNil(refused.part)
        XCTAssertNil(refused.conformance)
    }

    func test_commentsAndCdataInTheMetadataAreNotMistakenForADeclaration() {
        let xmp = "<x:xmpmeta xmlns:x='adobe:ns:meta/' xmlns:dc='http://purl.org/dc/elements/1.1/' xmlns:pdfaid='http://www.aiim.org/pdfa/ns/id/'>"
            + "<!-- &nbsp; <!DOCTYPE x> --><dc:description><![CDATA[R&D; <!DOCTYPE y>]]></dc:description>"
            + "<?note &nbsp; ?><pdfaid:part>1</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></x:xmpmeta>"
        let read = PdfDocument.readPdfAId(Array(xmp.utf8))
        XCTAssertEqual(read.part, 1)
        XCTAssertEqual(read.conformance, "B")
        let declared = PdfDocument.readPdfAId(Array(xmp.replacingOccurrences(of: "<pdfaid:part>", with: "&nbsp;<pdfaid:part>").utf8))
        XCTAssertNil(declared.part)
    }

    func test_versionIsTheHeadersOrTheCatalogsWhenNewer() throws {
        XCTAssertEqual(try open("").version, "1.4")
        XCTAssertEqual(try open("/Version /1.7").version, "1.7")
        XCTAssertEqual(try open("/Version /1.2").version, "1.4")
        XCTAssertEqual(try open("/Version 5").version, "1.4")
        let pdf = TestPdf("%PDF-2.0\n")
        XCTAssertEqual(try open("", pdf).version, "2.0")
        XCTAssertEqual(try PdfDocument.open(TestPdf.replace(TestPdf.simple(), "%PDF-1.4", "%PDF-x.y")).version, "1.4")
    }

    func test_infoAndIdAreRead() throws {
        let pdf = TestPdf().obj(5, "<</Title (A title) /Producer (Test)>>")
        let document = try open("", pdf, trailer: "/Root 1 0 R /Info 5 0 R /ID [<0102> (ab)]")
        XCTAssertEqual(TestPdf.text(try XCTUnwrap(document.info?["Title"] as? PdfString).bytes), "A title")
        XCTAssertEqual(document.id.count, 2)
        XCTAssertEqual(document.id[0], [1, 2])
        XCTAssertEqual(document.id[1], TestPdf.latin("ab"))
    }

    func test_infoAndIdComeFromAnOlderSectionWhenTheNewestLacksThem() throws {
        let first = TestPdf().obj(5, "<</Title (T)>>").obj(1, "<</Type /Catalog /Pages 2 0 R>>").obj(2, "<</Type /Pages /Kids [] /Count 0>>")
            .finish("/Root 1 0 R /Info 5 0 R /ID [<aa> <bb>]")
        let update = "5 0 obj\n<</Title (New)>>\nendobj\n"
        let start = first.count + update.count
        let previous = try XCTUnwrap(first.lastIndexOf(TestPdf.latin("xref\n0")))
        let section = "xref\n5 1\n\(String(format: "%010ld", first.count)) 00000 n \ntrailer\n<</Size 6 /Root 1 0 R /Prev \(previous)>>\nstartxref\n\(start)\n%%EOF\n"
        let document = try PdfDocument.open(first + TestPdf.latin(update + section))
        XCTAssertTrue(document.repairs.isEmpty)
        XCTAssertEqual(TestPdf.text(try XCTUnwrap(document.info?["Title"] as? PdfString).bytes), "New")
        XCTAssertEqual(document.id.count, 2)
    }
}
