import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactXmpTextTests.cs: the same cases. Words split over the text nodes and child
// elements of an element, names held in attributes, and a packet with very many parts to drop.

final class RedactXmpTextTests: XCTestCase {
    private let head = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
        + "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:dc='http://purl.org/dc/elements/1.1/'>"
    private let tail = "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"

    private func setPacket(_ document: PdfDocument, _ body: String) throws {
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        dictionary["Subtype"] = PdfName("XML")
        document.catalog["Metadata"] = try document.add(PdfStream(dictionary, data: Array((head + body + tail).utf8)))
    }

    private func withXmp(_ body: String) throws -> PdfDocument {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET")
        try setPacket(document, body)
        return document
    }

    private func redact(_ document: PdfDocument, _ change: Bool = false) throws -> RedactionResult {
        var options = RedactionOptions()
        options.changeMetadata = change
        return try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXMARKER"), options)
    }

    func test_wordSplitOverTheNodesOfATitleIsFoundAndReplaced() throws {
        for title in ["ZQX<![CDATA[MARKER]]>", "ZQX<!-- -->MARKER", "ZQX<b>MARKER</b>", "ZQX<b/>MARKER"] {
            let document = try withXmp("<dc:title>\(title)</dc:title>")
            let result = try redact(document, true)
            XCTAssertFalse(RedactionKit.holds(result.bytes, "MARKER"), title)
            XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        }
    }

    func test_phraseBrokenOverLinesInAPacketIsFoundAndReplaced() throws {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (ZQXFIRST ZQXSECOND) Tj ET")
        try setPacket(document, "<dc:title>about ZQXFIRST\n      ZQXSECOND here</dc:title>")
        var options = RedactionOptions()
        options.changeMetadata = true
        let result = try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, "ZQXFIRST ZQXSECOND"), options)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXSECOND"))
        XCTAssertTrue(RedactionKit.holds(result.bytes, "about [redacted] here"))
    }

    func test_wordSplitOverTheNodesOfATitleIsReportedWhenNothingMayChange() throws {
        let document = try withXmp("<dc:title>ZQX<![CDATA[MARKER]]></dc:title>")
        let result = try redact(document)
        XCTAssertFalse(result.verification.isClean)
    }

    func test_namesOfPageCopiesHeldInAttributesAreDropped() throws {
        let document = try withXmp("<dc:item xmpMM:DerivedFrom=\"ZQXDID\" xmpMM:ManagedFrom=\"ZQXMID\" dc:kept=\"yes\"/>")
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXDID"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMID"))
        XCTAssertTrue(RedactionKit.holds(result.bytes, "dc:kept"))
    }

    func test_versionsAndAncestorsAreDropped() throws {
        let document = try withXmp("<xmpMM:Versions><rdf:Seq><rdf:li><dc:comments>ZQXVERSION</dc:comments></rdf:li></rdf:Seq></xmpMM:Versions>"
            + "<photoshop:DocumentAncestors><rdf:Bag><rdf:li>ZQXANCESTOR</rdf:li></rdf:Bag></photoshop:DocumentAncestors>")
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXVERSION"))
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXANCESTOR"))
    }

    func test_packetTheWriterRefusesIsEmptiedNotKept() throws {
        let document = try withXmp("<dc:title>ZQXMARKER</dc:title><dc:x xmlns='a' xmlns:xmlns='b'/>")
        let result = try redact(document, true)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXMARKER"))
        XCTAssertTrue(result.report.findings.contains { $0.where == RedactionText.xmpUnreadable })
    }

    func test_manyDroppedElementsAmongKeptOnesAreTakenOutInLinearTime() throws {
        let document = try withXmp(String(repeating: "<dc:k/><xmpMM:History/>", count: 50_000))
        let start = Date()
        let result = try redact(document)
        let took = Date().timeIntervalSince(start)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "History"))
        XCTAssertTrue(RedactionKit.holds(result.bytes, "dc:k"))
        XCTAssertTrue(took < 10, "took \(took)")
    }
}
