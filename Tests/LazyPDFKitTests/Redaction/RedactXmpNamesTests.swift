import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Redaction/RedactXmpNamesTests.cs: the same cases. XMP found by what it is and not by how
// it is spelled, packets held by direct dictionaries, wide encodings with a mark, and the other places removed words can hide.

final class RedactXmpNamesTests: XCTestCase {
    private let head = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
        + "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:stRef='http://ns.adobe.com/xap/1.0/sType/ResourceRef#' xmlns:dc='http://purl.org/dc/elements/1.1/' "
        + "xmlns:x-mp='urn:mp' xmlns:x-g='urn:g' xmlns:xmp='http://ns.adobe.com/xap/1.0/'>"
    private let tail = "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>"

    private func open(_ text: String = "ZQXMARKER", _ more: ((PdfDocument) throws -> Void)? = nil) throws -> PdfDocument {
        let document = try RedactionKit.page("BT /F1 12 Tf 50 700 Td (\(text)) Tj ET")
        try more?(document)
        return document
    }

    private func packet(_ document: PdfDocument, _ data: [UInt8]) throws -> PdfReference {
        let dictionary = PdfDictionary()
        dictionary["Type"] = PdfName("Metadata")
        dictionary["Subtype"] = PdfName("XML")
        return try document.add(PdfStream(dictionary, data: data))
    }

    private func redact(_ document: PdfDocument, _ word: String = "ZQXMARKER", _ change: Bool = false) throws -> RedactionResult {
        var options = RedactionOptions()
        options.changeMetadata = change
        return try PdfRedactor(document).apply(try RedactionKit.marksOf(document, 0, word), options)
    }

    private func withXmp(_ body: String) throws -> RedactionResult {
        let document = try open { d in d.catalog["Metadata"] = try self.packet(d, Array((self.head + body + self.tail).utf8)) }
        return try redact(document)
    }

    func test_thumbnailUnderAPrefixWithAHyphenIsDropped() throws {
        let result = try withXmp("<x-mp:Thumbnails><rdf:Alt><rdf:li><x-g:image>ZQXPAGEIMAGE</x-g:image></rdf:li></rdf:Alt></x-mp:Thumbnails>")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPAGEIMAGE"))
    }

    func test_thumbnailInADefaultNamespaceIsDropped() throws {
        let result = try withXmp("<Thumbnails xmlns='urn:t'><image xmlns='urn:i'>ZQXPAGEIMAGE</image></Thumbnails>")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPAGEIMAGE"))
    }

    func test_idsAreFoundWhateverTheCaseAndTheElementThatHoldsThem() throws {
        let result = try withXmp("<xmpMM:ManagedFrom stRef:documentID=\"ZQXDID\" stRef:instanceID=\"ZQXIID\"/><xmpMM:RenditionOf><rdf:Description stRef:instanceID=\"ZQXRID\"/></xmpMM:RenditionOf>")
        for word in ["ZQXDID", "ZQXIID", "ZQXRID"] { XCTAssertFalse(RedactionKit.holds(result.bytes, word), word) }
    }

    func test_attributeValueWithAGreaterThanSignDoesNotEndTheElementEarly() throws {
        let result = try withXmp("<xmpMM:DerivedFrom stRef:filePath=\"a>b\" stRef:documentID=\"ZQXDID\"/>")
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXDID"))
    }

    func test_packetNamedByADirectDictionaryOfAnObjectIsVisited() throws {
        let xmp = head + "<xmp:Thumbnails><rdf:Alt><rdf:li>ZQXPAGEIMAGE</rdf:li></rdf:Alt></xmp:Thumbnails>" + tail
        let document = try open { d in
            let group = PdfDictionary()
            group["S"] = PdfName("Transparency")
            group["Metadata"] = try d.add(PdfStream(PdfDictionary(), data: Array(xmp.utf8)))
            d.pages[0].dictionary["Group"] = group
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXPAGEIMAGE"))
    }

    func test_widePacketWithItsMarkAtTheFirstByteIsRead() throws {
        for bigEndian in [true, false] {
            var data: [UInt8] = bigEndian ? [0, 0, 0xFE, 0xFF] : [0xFF, 0xFE, 0, 0]
            for scalar in (head + "<xmpMM:History>ZQXHISTORY</xmpMM:History>" + tail).unicodeScalars {
                let v = scalar.value
                data += bigEndian ? [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
                                  : [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
            }
            let document = try open { d in d.catalog["Metadata"] = try self.packet(d, data) }
            let result = try redact(document)
            let wide = "ZQXHISTORY".unicodeScalars.flatMap { s -> [UInt8] in
                bigEndian ? [0, 0, 0, UInt8(s.value)] : [UInt8(s.value), 0, 0, 0]
            }
            XCTAssertFalse(try RedactionKit.everything(result.bytes).contains(Latin1.string(wide)))
        }
    }

    func test_characterReferenceDoesNotHideRemovedTextFromTheSearch() throws {
        let xmp = head + "<dc:title>J&#97;ne Doe</dc:title>" + tail
        let document = try open("Jane Doe") { d in d.catalog["Metadata"] = try self.packet(d, Array(xmp.utf8)) }
        let result = try redact(document, "Jane Doe", true)
        XCTAssertFalse(try RedactionKit.everything(result.bytes).contains("J&#97;ne"))
        XCTAssertTrue(result.report.findings.contains { $0.where == "The XMP metadata" && $0.changed })
    }

    func test_verifyFindsRemovedTextBehindACharacterReference() throws {
        let xmp = head + "<dc:title>J&#97;ne Doe</dc:title>" + tail
        let document = try open("Jane Doe") { d in d.catalog["Metadata"] = try self.packet(d, Array(xmp.utf8)) }
        let problems = PdfRedactor.verify(try document.saveRewrite(), [], ["Jane Doe"]).problems
        XCTAssertFalse(problems.isEmpty)
    }

    func test_packetThatIsNotXmlIsEmptiedAtOnce() throws {
        let data = Array(String(repeating: "<a:image </", count: 30_000).utf8)
        let document = try open { d in d.catalog["Metadata"] = try self.packet(d, data) }
        let result = try redact(document)
        XCTAssertTrue(result.report.findings.contains { $0.where == RedactionText.xmpUnreadable })
    }

    func test_packetOverTheSizeLimitIsEmptiedAndReported() throws {
        let data = [UInt8](repeating: 0x20, count: (16 << 20) + 1)
        let document = try open { d in d.catalog["Metadata"] = try self.packet(d, data) }
        let result = try redact(document)
        XCTAssertTrue(result.report.findings.contains { $0.where == RedactionText.xmpUnreadable })
        XCTAssertTrue(result.bytes.count < 1 << 20)
    }

    func test_nameThatHoldsRemovedWordsIsRenamed() throws {
        let document = try open("Jane Doe") { d in
            let dests = PdfDictionary()
            dests["Jane Doe"] = PdfArray([PdfName("Fit")])
            d.catalog["Dests"] = dests
        }
        let result = try redact(document, "Jane Doe", true)
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertFalse(try XCTUnwrap(output.dict(output.catalog, "Dests")).entries.contains { $0.key.contains("Jane") })
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
    }

    func test_verifyFindsRemovedTextHeldInAName() throws {
        let document = try open("Jane Doe") { d in
            let dests = PdfDictionary()
            dests["Jane Doe"] = PdfArray([PdfName("Fit")])
            d.catalog["Dests"] = dests
        }
        let problems = PdfRedactor.verify(try document.saveRewrite(), [], ["Jane Doe"]).problems
        XCTAssertFalse(problems.isEmpty)
    }

    func test_namesTheFormatDefinesAreLeftWhateverTheWordsAre() throws {
        let document = try open("Page Type") { d in
            let dests = PdfDictionary()
            dests["Fit"] = PdfName("Type")
            d.catalog["Dests"] = dests
        }
        let result = try redact(document, "Page Type")
        XCTAssertTrue(result.verification.isClean, result.verification.problems.joined(separator: "; "))
        let output = try RedactionKit.reopen(result.bytes)
        XCTAssertEqual(output.name(output.pages[0].dictionary, "Type"), "Page")
    }

    func test_fileAttachedToThePageDoesNotStay() throws {
        let document = try open { d in
            let dictionary = PdfDictionary()
            dictionary["Type"] = PdfName("EmbeddedFile")
            let file = try d.add(PdfStream(dictionary, data: Latin1.bytes("ZQXATTACHEDSOURCE")))
            let files = PdfDictionary()
            files["F"] = file
            let spec = PdfDictionary()
            spec["Type"] = PdfName("Filespec")
            spec["EF"] = files
            d.pages[0].dictionary["AF"] = PdfArray([spec])
        }
        let result = try redact(document)
        XCTAssertFalse(RedactionKit.holds(result.bytes, "ZQXATTACHEDSOURCE"))
    }
}
