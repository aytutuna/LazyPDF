import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/MetadataTests.cs: the same cases. PdfPigReadsTheInfo has no twin (PdfPig).
// WriteKeepsXmpInStepAndKeepsOtherProperties reads the saved packet with the XmlTree reader where the C# uses XDocument.

final class MetadataTests: XCTestCase {
    private static let packet = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/" pdfaid:part="2" pdfaid:conformance="B" pdf:Producer="Old producer"
            xmp:CreatorTool="Old tool" xmp:CreateDate="2020-01-02T03:04:05+01:00">
           <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/"><rdf:Alt><rdf:li xml:lang="x-default">Old title</rdf:li></rdf:Alt></dc:title>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

    private func withXmp(_ xml: String, _ streamEntries: String = "", info: String = "") throws -> PdfDocument {
        try StructureFixtures.file("/Metadata 30 0 R", { pdf in
            pdf.stream(30, "/Type /Metadata /Subtype /XML " + streamEntries, xml)
            if !info.isEmpty { pdf.obj(31, info) }
        })
    }

    private func sample() -> DocumentMetadata {
        DocumentMetadata(
            "Annual report", "A. Writer", "Numbers", "money, year", "Word", "Lazy",
            DateTimeOffset(2026, 1, 2, 3, 4, 5, offsetMinutes: 180), DateTimeOffset(2026, 2, 3, 4, 5, 6, offsetMinutes: -300),
            ["Department": "Finance", "Code": "42"])
    }

    private func metadataText(_ document: PdfDocument) throws -> String {
        let stream = try XCTUnwrap(document.stream(document.catalog, "Metadata"))
        return String(decoding: try document.data(stream), as: UTF8.self)
    }

    func test_writesAndReadsInfoOfAFileWithoutOne() throws {
        let document = try StructureFixtures.open()
        XCTAssertNil(document.info)
        try sample().write(document)
        let reopened = try StructureFixtures.reopen(document)
        let read = DocumentMetadata.read(reopened)
        let expected = sample()
        XCTAssertEqual([expected.title, expected.author, expected.subject, expected.keywords, expected.creator, expected.producer],
                       [read.title, read.author, read.subject, read.keywords, read.creator, read.producer])
        XCTAssertEqual(expected.created, read.created)
        XCTAssertEqual(expected.modified, read.modified)
        XCTAssertEqual(expected.custom, read.custom)
    }

    func test_nonLatinTextUsesUtf16() throws {
        let document = try StructureFixtures.open()
        var metadata = sample()
        metadata.title = "\u{414}\u{43E}\u{43A}\u{43B}\u{430}\u{434}"
        metadata.custom = ["Note": "T\u{FC}rk\u{E7}e \u{11F}"]
        try metadata.write(document)
        let read = DocumentMetadata.read(try StructureFixtures.reopen(document))
        XCTAssertEqual(read.title, "\u{414}\u{43E}\u{43A}\u{43B}\u{430}\u{434}")
        XCTAssertEqual(read.custom["Note"], "T\u{FC}rk\u{E7}e \u{11F}")
    }

    func test_nullAndEmptyRemoveKeys() throws {
        let document = try StructureFixtures.open()
        try sample().write(document)
        var metadata = sample()
        metadata.title = nil
        metadata.author = ""
        metadata.created = nil
        metadata.custom = OrderedStrings()
        try metadata.write(document)
        let read = DocumentMetadata.read(document)
        XCTAssertNil(read.title)
        XCTAssertNil(read.author)
        XCTAssertNil(read.created)
        XCTAssertTrue(read.custom.isEmpty)
        XCTAssertEqual(document.info?.containsKey("Title"), false)
        XCTAssertEqual(read.subject, "Numbers")
    }

    func test_entriesNotInTheRecordAreKept() throws {
        let document = try withXmp("<x/>", info: "<</Title (T) /Trapped /True /Number 5 /Custom (x) /Dated (D:20200101000000Z)>>")
        document.trailer["Info"] = PdfReference(31, 0)
        var read = DocumentMetadata.read(document)
        XCTAssertEqual(read.custom.keys, ["Custom", "Dated"])
        read.custom = OrderedStrings()
        try read.write(document)
        let info = try XCTUnwrap(document.info)
        XCTAssertEqual(info["Trapped"]?.description, "/True")
        XCTAssertEqual(info["Number"]?.description, "5")
        XCTAssertNil(info["Custom"])
    }

    func test_standardNamesAreNotCustom() throws {
        let document = try StructureFixtures.open()
        var metadata = sample()
        metadata.custom = ["Title": "sneaky", "Trapped": "True", "": "x", "Fine": "y"]
        try metadata.write(document)
        let read = DocumentMetadata.read(document)
        XCTAssertEqual(read.title, "Annual report")
        XCTAssertEqual(read.custom.keys, ["Fine"])
        XCTAssertNil(document.info?["Trapped"])
    }

    func test_readsDirectInfoAndBrokenDates() throws {
        let document = try StructureFixtures.open()
        let info = PdfDictionary()
        info["Title"] = PdfString(bytes: Array("direct".utf8), isHex: false)
        info["CreationDate"] = PdfString(bytes: Array("yesterday".utf8), isHex: false)
        document.trailer["Info"] = info
        let read = DocumentMetadata.read(document)
        XCTAssertEqual(read.title, "direct")
        XCTAssertNil(read.created)
        try read.write(document)
        XCTAssertEqual(DocumentMetadata.read(try StructureFixtures.reopen(document)).title, "direct")
    }

    func test_xmpFillsWhatInfoLacks() throws {
        let document = try withXmp(Self.packet)
        let read = DocumentMetadata.read(document)
        XCTAssertEqual([read.title, read.producer, read.creator], ["Old title", "Old producer", "Old tool"])
        XCTAssertEqual(read.created, DateTimeOffset(2020, 1, 2, 3, 4, 5, offsetMinutes: 60))
        XCTAssertNil(read.author)
    }

    func test_infoWinsOverXmp() throws {
        let document = try withXmp(Self.packet, info: "<</Title (From info)>>")
        document.trailer["Info"] = PdfReference(31, 0)
        XCTAssertEqual(DocumentMetadata.read(document).title, "From info")
    }

    func test_writeKeepsXmpInStepAndKeepsOtherProperties() throws {
        let document = try withXmp(Self.packet)
        try sample().write(document)
        let reopened = try StructureFixtures.reopen(document)

        let stream = try XCTUnwrap(reopened.stream(reopened.catalog, "Metadata"))
        let bytes = try reopened.data(stream)
        let text = String(decoding: bytes, as: UTF8.self)
        let xml = try XCTUnwrap(XmlDocument.parse(bytes))
        let rdf = XmpPacket.rdf, dc = XmpPacket.dc, pdf = XmpPacket.pdf, xmp = XmpPacket.xmp, pdfx = XmpPacket.pdfx
        let id = "http://www.aiim.org/pdfa/ns/id/"
        let root = try XCTUnwrap(xml.root)
        let descriptions = root.firstDescendant(XmlName(rdf, "RDF"))?.elements(XmlName(rdf, "Description")) ?? []
        XCTAssertEqual(descriptions.count, 1)
        let description = try XCTUnwrap(descriptions.first)
        func item(_ ns: String, _ name: String) -> String? {
            description.element(XmlName(ns, name))?.firstDescendant(XmlName(rdf, "li"))?.value
        }
        XCTAssertEqual(item(dc, "title"), "Annual report")
        XCTAssertEqual(item(dc, "creator"), "A. Writer")
        XCTAssertEqual(item(dc, "description"), "Numbers")
        XCTAssertEqual(description.element(XmlName(pdf, "Keywords"))?.value, "money, year")
        XCTAssertEqual(description.element(XmlName(pdf, "Producer"))?.value, "Lazy")
        XCTAssertNil(description.attribute(XmlName(pdf, "Producer")))
        XCTAssertEqual(description.element(XmlName(xmp, "CreatorTool"))?.value, "Word")
        XCTAssertEqual(description.element(XmlName(xmp, "CreateDate"))?.value, "2026-01-02T03:04:05+03:00")
        XCTAssertEqual(description.element(XmlName(xmp, "ModifyDate"))?.value, "2026-02-03T04:05:06-05:00")
        XCTAssertEqual(description.element(XmlName(pdfx, "Department"))?.value, "Finance")
        XCTAssertEqual(description.attribute(XmlName(id, "part"))?.value, "2")

        // The packet markers stay, so tools that look for them still find the metadata.
        XCTAssertTrue(text.contains("<?xpacket begin="))
        XCTAssertTrue(text.contains("<?xpacket end=\"w\"?>"))
        XCTAssertEqual(DocumentMetadata.read(reopened).title, "Annual report")
        XCTAssertEqual(DocumentMetadata.read(reopened).subject, "Numbers")
        XCTAssertEqual(reopened.pdfAPart, 2)
    }

    func test_removingAValueRemovesItFromXmp() throws {
        let document = try withXmp(Self.packet)
        var read = DocumentMetadata.read(document)
        read.title = nil
        read.creator = nil
        try read.write(document)
        let text = try metadataText(document)
        XCTAssertFalse(text.contains("Old title"))
        XCTAssertFalse(text.contains("Old tool"))
        XCTAssertTrue(text.contains("Old producer"))
    }

    func test_rewritingCustomKeysUpdatesTheirXmpCounterparts() throws {
        let document = try withXmp(Self.packet)
        var first = sample()
        first.custom = ["A": "1", "bad key": "2"]
        try first.write(document)
        var second = sample()
        second.custom = ["B": "3"]
        try second.write(document)
        let text = try metadataText(document)
        XCTAssertFalse(text.contains("pdfx:A"))
        XCTAssertTrue(text.contains(">3</pdfx:B>"))
        XCTAssertFalse(text.contains("bad key"))
    }

    func test_flateXmpIsStoredPlainAfterAWrite() throws {
        let document = try StructureFixtures.file("/Metadata 30 0 R", { pdf in
            pdf.stream(30, "/Type /Metadata /Subtype /XML /Filter /FlateDecode", PdfFilterEncoders.flate(Array(Self.packet.utf8)))
        })
        try sample().write(document)
        let stream = try XCTUnwrap(document.stream(document.catalog, "Metadata"))
        XCTAssertNil(stream.dictionary["Filter"])
        XCTAssertTrue(String(decoding: try document.data(stream), as: UTF8.self).contains("Annual report"))
        let reopened = try StructureFixtures.reopen(document)
        XCTAssertTrue(try metadataText(reopened).contains("Annual report"))
    }

    func test_noXmpIsNotMade() throws {
        let document = try StructureFixtures.open()
        try sample().write(document)
        XCTAssertNil(document.catalog["Metadata"])
    }

    func test_xmpThatCannotBeUsedIsLeftAlone() throws {
        let cases = [
            "this is not xml <<<",
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><nothing/></x:xmpmeta>",
            "<!DOCTYPE r [<!ENTITY a \"aaaa\"><!ENTITY b \"&a;&a;&a;&a;\">]><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">&b;</rdf:RDF>",
        ]
        for xml in cases {
            let document = try withXmp(xml)
            try sample().write(document)
            XCTAssertEqual(try metadataText(document), xml, xml)
            XCTAssertEqual(DocumentMetadata.read(document).title, "Annual report", xml)
        }
    }

    func test_xmpBehindACryptFilterIsLeftAlone() throws {
        let document = try StructureFixtures.file("/Metadata 30 0 R", { pdf in
            pdf.stream(30, "/Type /Metadata /Subtype /XML /Filter [/Crypt] /DecodeParms [<</Name /Identity>>]", Self.packet)
        })
        try sample().write(document)
        let stream = try XCTUnwrap(document.stream(document.catalog, "Metadata"))
        XCTAssertTrue(TestPdf.contains(document.rawData(stream), "Old title"))
    }

    func test_worksInAnEncryptedDocument() throws {
        let id = (1...16).map { UInt8($0) }
        let security = PdfSecurity.create(userPassword: "", ownerPassword: "owner", permissions: .all, strength: .aes128, firstId: id,
                                          random: SeededRandom(5))
        let encrypted = try PdfDocument.open(StructureFixtures.open().saveRewrite(PdfSaveOptions(security: security, documentId: id)))
        try sample().write(encrypted)
        let reopened = try PdfDocument.open(encrypted.saveIncremental())
        XCTAssertEqual(DocumentMetadata.read(reopened).title, "Annual report")
        XCTAssertEqual(DocumentMetadata.read(reopened).custom["Department"], "Finance")
    }

    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let dcNs = "http://purl.org/dc/elements/1.1/"

    private func withBytes(_ packet: [UInt8]) throws -> PdfDocument {
        try StructureFixtures.file("/Metadata 30 0 R", { pdf in pdf.stream(30, "/Type /Metadata /Subtype /XML", packet) })
    }

    private func packetBytes(_ document: PdfDocument) throws -> [UInt8] {
        let stream = try XCTUnwrap(document.stream(document.catalog, "Metadata"))
        return try document.data(stream)
    }

    // Unit size 2 is UTF-16 and 4 is UTF-32, in either byte order, with a byte order mark or without.
    private func wide(_ text: String, size: Int, bigEndian: Bool, mark: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        func put(_ unit: UInt32) {
            let one = (0..<size).map { UInt8(truncatingIfNeeded: unit >> UInt32(8 * $0)) }
            bytes += bigEndian ? one.reversed() : one
        }
        if mark { put(0xFEFF) }
        if size == 2 {
            for unit in text.utf16 { put(UInt32(unit)) }
        } else {
            for scalar in text.unicodeScalars { put(scalar.value) }
        }
        return bytes
    }

    func test_charactersXmlForbidsAreLeftOutOfXmp() throws {
        let document = try withXmp(Self.packet)
        var metadata = sample()
        metadata.title = "A\u{1}B\u{FFFE}"
        metadata.subject = "a\r\nb\rc"
        metadata.keywords = "k\u{8};m"
        try metadata.write(document)
        let text = try metadataText(document)
        XCTAssertTrue(text.contains(">AB</rdf:li>"), text)
        XCTAssertTrue(text.contains(">a\nb\nc</rdf:li>"), text)
        XCTAssertTrue(text.contains("<rdf:li>k</rdf:li><rdf:li>m</rdf:li>"), text)
        XCTAssertNotNil(XmpPacket.load(document))
    }

    func test_packetThatIsNotUtf8IsLeftAlone() throws {
        let latin1 = Latin1.bytes("<rdf:RDF xmlns:rdf=\"\(Self.rdf)\"><rdf:Description xmlns:dc=\"\(Self.dcNs)\"><dc:title>caf\u{E9}</dc:title></rdf:Description></rdf:RDF>")
        let document = try withBytes(latin1)
        XCTAssertNil(DocumentMetadata.read(document).title)
        try sample().write(document)
        XCTAssertEqual(try packetBytes(document), latin1)
    }

    func test_xmpIsReadInTheEncodingsXmlReaderKnows() throws {
        let body = "<rdf:RDF xmlns:rdf=\"\(Self.rdf)\"><rdf:Description xmlns:dc=\"\(Self.dcNs)\"><dc:title>caf\u{E9}</dc:title></rdf:Description></rdf:RDF>"
        func declared(_ name: String) -> String { "<?xml version=\"1.0\" encoding=\"\(name)\"?>" }
        let cases: [(name: String, bytes: [UInt8], title: String)] = [
            ("utf-16le", wide(body, size: 2, bigEndian: false, mark: false), "caf\u{E9}"),
            ("utf-16le mark", wide(body, size: 2, bigEndian: false, mark: true), "caf\u{E9}"),
            ("utf-16be", wide(body, size: 2, bigEndian: true, mark: false), "caf\u{E9}"),
            ("utf-16 declared", wide(declared("utf-16") + body, size: 2, bigEndian: false, mark: false), "caf\u{E9}"),
            ("utf-32le mark", wide(body, size: 4, bigEndian: false, mark: true), "caf\u{E9}"),
            ("utf-32be", wide(body, size: 4, bigEndian: true, mark: false), "caf\u{E9}"),
            ("utf-32be mark", wide(body, size: 4, bigEndian: true, mark: true), "caf\u{E9}"),
            ("latin-1 declared", Latin1.bytes(declared("ISO-8859-1") + body), "caf\u{E9}"),
            ("ascii declared", Latin1.bytes(declared("ascii") + body), "caf?"),
            ("utf-8 mark and latin-1 declared", [0xEF, 0xBB, 0xBF] + Array((declared("latin1") + body).utf8), "caf\u{C3}\u{A9}"),
        ]
        for c in cases {
            XCTAssertEqual(DocumentMetadata.read(try withBytes(c.bytes)).title, c.title, c.name)
        }
    }

    func test_xmpInAnEncodingXmlReaderRefusesIsLeftAlone() throws {
        let body = "<rdf:RDF xmlns:rdf=\"\(Self.rdf)\"/>"
        let open = "<rdf:RDF xmlns:rdf=\"\(Self.rdf)\">a"
        let surrogate8: [UInt8] = Array(open.utf8) + [0xED, 0xA0, 0x80] + Array("</rdf:RDF>".utf8)
        let loneHigh: [UInt8] = [0xFF, 0xFE] + wide(open, size: 2, bigEndian: false, mark: false) + [0x00, 0xD8]
        let cases: [[UInt8]] = [
            wide("<?xml version=\"1.0\" encoding=\"utf-8\"?>" + body, size: 2, bigEndian: false, mark: false),
            Array(("<?xml version=\"1.0\" encoding=\"utf-16\"?>" + body).utf8),
            Latin1.bytes("<?xml version=\"1.0\" encoding=\"no-such-encoding\"?>" + body),
            surrogate8,
            loneHigh + wide("</rdf:RDF>", size: 2, bigEndian: false, mark: false),
        ]
        for bytes in cases {
            let document = try withBytes(bytes)
            try sample().write(document)
            XCTAssertEqual(try packetBytes(document), bytes)
        }
    }

    func test_xmpThatXmlReaderRefusesIsLeftAlone() throws {
        let rdf = Self.rdf
        let cases = [
            "<?xml foo=\"1\" version=\"1.0\"?><rdf:RDF xmlns:rdf=\"\(rdf)\"/>",
            "<?xml version=\"1.0\" standalone=\"yes\" encoding=\"utf-8\"?><rdf:RDF xmlns:rdf=\"\(rdf)\"/>",
            "<rdf:RDF xmlns:rdf=\"\(rdf)\" xmlns=\"http://www.w3.org/2000/xmlns/\"/>",
            "<rdf:RDF xmlns:rdf=\"\(rdf)\"><\u{132}/></rdf:RDF>",
            "<rdf:RDF xmlns:rdf=\"\(rdf)\"><\u{E9}></e\u{301}></rdf:RDF>",
            "<rdf:RDF xmlns:rdf=\"\(rdf)\">&#X41;</rdf:RDF>",
            "<rdf:RDF xmlns:rdf=\"\(rdf)\">&#x110000;</rdf:RDF>",
        ]
        for xml in cases {
            let bytes = Array(xml.utf8)
            let document = try withBytes(bytes)
            try sample().write(document)
            XCTAssertEqual(try packetBytes(document), bytes, xml)
        }
    }

    func test_xmpThatXmlReaderAcceptsIsRead() throws {
        let rdf = Self.rdf, dc = Self.dcNs
        let cases = [
            "<rdf:RDF xmlns:rdf=\"\(rdf)\"><rdf:Description xmlns:dc=\"\(dc)\"><dc:title>&#x0000000000041;</dc:title></rdf:Description></rdf:RDF>",
            "<rdf:RDF xmlns:rdf=\"\(rdf)\"><rdf:Description xmlns:dc=\"\(dc)\" \u{E9}=\"1\" e\u{301}=\"2\"><dc:title>A</dc:title></rdf:Description></rdf:RDF>",
            "<?xml version=\"1.0\" standalone=\"no\"?><rdf:RDF xmlns:rdf=\"\(rdf)\"><rdf:Description xmlns:dc=\"\(dc)\"><dc:title>A</dc:title></rdf:Description></rdf:RDF>",
        ]
        for xml in cases {
            XCTAssertEqual(DocumentMetadata.read(try withBytes(Array(xml.utf8))).title, "A", xml)
        }
    }

    func test_namesXmlConvertRefusesAreNotCustomKeys() throws {
        let document = try withXmp(Self.packet)
        var metadata = sample()
        metadata.custom = ["\u{132}": "x", "Fine": "y"]
        try metadata.write(document)
        let text = try metadataText(document)
        XCTAssertFalse(text.contains("\u{132}"), text)
        XCTAssertTrue(text.contains(">y</pdfx:Fine>"), text)
    }

    func test_prefixesAreChosenAgainWhenThePacketIsWritten() throws {
        let twice = try withXmp("<a:RDF xmlns:a=\"\(Self.rdf)\" xmlns:b=\"\(Self.rdf)\"><a:Description/></a:RDF>")
        try sample().write(twice)
        var text = try metadataText(twice)
        XCTAssertTrue(text.contains("<b:RDF "), text)
        XCTAssertTrue(text.contains("<b:Description "), text)

        let byDefault = try withXmp("<rdf:RDF xmlns:rdf=\"\(Self.rdf)\"><rdf:Description xmlns=\"\(Self.dcNs)\"/></rdf:RDF>")
        try sample().write(byDefault)
        text = try metadataText(byDefault)
        XCTAssertTrue(text.contains("xmlns:dc="), text)
        XCTAssertTrue(text.contains("<dc:title>"), text)
        XCTAssertNotNil(XmpPacket.load(byDefault))
    }

    func test_attributeInTheOnlyDefaultNamespaceGetsAPrefix() throws {
        let document = try withXmp("<RDF xmlns=\"\(Self.rdf)\"/>")
        try sample().write(document)
        XCTAssertNotNil(XmpPacket.load(document))
        XCTAssertTrue(try metadataText(document).contains("<Description p"))
    }

    // Not in the C# tests: the reader and the writer take time in proportion to the packet, not its square.
    func test_aPacketWithManyAttributesAndNamespacesIsHandledInLinearTime() throws {
        let start = Date()
        let attributes = (0..<200_000).map { "a\($0)=\"1\"" }.joined(separator: " ")
        let wideTag = "<rdf:RDF xmlns:rdf=\"\(Self.rdf)\"><rdf:Description \(attributes)/></rdf:RDF>"
        var document = try withBytes(Array(wideTag.utf8))
        try sample().write(document)
        XCTAssertEqual(DocumentMetadata.read(document).title, "Annual report")

        let declarations = (0..<600).map { "xmlns:p\($0)=\"urn:p\($0)\"" }.joined(separator: " ")
        let nested = String(repeating: "<n \(declarations)>", count: 300)
        let deep = "<rdf:RDF xmlns:rdf=\"\(Self.rdf)\"><rdf:Description>" + nested + String(repeating: "<c/>", count: 100_000)
            + String(repeating: "</n>", count: 300) + "</rdf:Description></rdf:RDF>"
        document = try withBytes(Array(deep.utf8))
        try sample().write(document)
        XCTAssertEqual(DocumentMetadata.read(document).title, "Annual report")
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }
}
