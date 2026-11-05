import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAMetadataTests.cs: the same cases.

final class PdfAMetadataTests: XCTestCase {
    private func withPacket(_ level: PdfALevel = .a2b, _ edit: (String) -> String) -> [UInt8] {
        StandardsKit.compliant(level, xmp: edit(StandardsKit.packet(level)))
    }

    func test_aFileWithoutMetadataIsReported() throws {
        let file = try StandardsKit.edited(StandardsKit.compliant()) { d in d.catalog.remove("Metadata") }
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.6.2.1")
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.7.2")
    }

    func test_aPacketThatIsNotWellFormedIsReported() throws {
        StandardsKit.assertHas(try StandardsKit.check(withPacket { $0.replacingOccurrences(of: "</rdf:RDF>", with: "") }).issues) { $0.clause == "6.6.2.1" && $0.message.contains("well-formed") }
        StandardsKit.assertHas(try StandardsKit.check(withPacket { _ in "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>" }).issues) { $0.message.contains("rdf:RDF") }
    }

    func test_aDoctypeInThePacketIsNotRead() throws {
        let file = withPacket { "<!DOCTYPE x [<!ENTITY a \"b\">]>" + $0 }
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.6.2.1")
    }

    func test_theIdentificationHasToNameThePartAndLevel() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withPacket { $0.replacingOccurrences(of: "<pdfaid:part>2</pdfaid:part>", with: "") }), "6.6.4")
        StandardsKit.assertHas(try StandardsKit.check(withPacket { $0.replacingOccurrences(of: "<pdfaid:part>2<", with: "<pdfaid:part>1<") }).issues) { $0.message.contains("part 1") }
        StandardsKit.assertContains(try StandardsKit.clauses(withPacket { $0.replacingOccurrences(of: "<pdfaid:conformance>B<", with: "<pdfaid:conformance>X<") }), "6.6.4")
        StandardsKit.assertContains(try StandardsKit.clauses(withPacket(.a2b) { $0.replacingOccurrences(of: "<pdfaid:part>2<", with: "<pdfaid:part>3<") }, .a1b), "6.7.11")
    }

    func test_levelUAsksForUAndLevelBAcceptsBoth() throws {
        let b = StandardsKit.compliant(.a2b)
        let u = StandardsKit.compliant(.a2u)
        StandardsKit.assertContains(try StandardsKit.clauses(b, .a2u), "6.6.4")
        try StandardsKit.assertClean(u, .a2b)
        try StandardsKit.assertClean(u, .a2u)
    }

    func test_part4NeedsTheRevisionAndNoLevel() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(withPacket(.a4) { $0.replacingOccurrences(of: "<pdfaid:rev>2020</pdfaid:rev>", with: "") }, .a4), "6.6.4")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a4, info: "<</Title (x) /CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)>>"), .a4), "6.1.3")
    }

    func test_infoEntriesHaveToAgreeWithTheXmp() throws {
        let title = StandardsKit.compliant(info: "<</Title (Other) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)>>")
        StandardsKit.assertHas(try StandardsKit.check(title).issues) { $0.clause == "6.6.2.3" && $0.message.contains("/Title") }
        StandardsKit.assertContains(try StandardsKit.clauses(title, .a1b), "6.7.3")

        let date = StandardsKit.compliant(info: "<</Title (Title) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103001Z) /ModDate (D:20260304103000Z)>>")
        StandardsKit.assertHas(try StandardsKit.check(date).issues) { $0.message.contains("/CreationDate") }

        let extra = StandardsKit.compliant(info: "<</Title (Title) /Author (Someone) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)>>")
        StandardsKit.assertHas(try StandardsKit.check(extra).issues) { $0.message.contains("/Author") }
    }

    func test_aDateInAnotherZoneIsTheSameMoment() throws {
        let file = StandardsKit.compliant(info: "<</Title (Title) /Creator (Test) /Producer (Test) /CreationDate (D:20260304123000+02'00') /ModDate (D:20260304123000+02'00')>>")
        try StandardsKit.assertClean(file)
    }

    func test_propertiesOfAnUnknownSchemaNeedAnExtensionSchema() throws {
        let file = withPacket { $0.replacingOccurrences(of: "<pdfaid:part>", with: "<foo:bar xmlns:foo=\"http://example.com/foo/\">1</foo:bar><pdfaid:part>") }
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.clause == "6.6.2.3.1" && $0.message.contains("http://example.com/foo/") }
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.7.8")
    }

    func test_aDeclaredExtensionSchemaPasses() throws {
        let schema = "<pdfaExtension:schemas xmlns:pdfaExtension=\"http://www.aiim.org/pdfa/ns/extension/\" xmlns:pdfaSchema=\"http://www.aiim.org/pdfa/ns/schema#\" "
            + "xmlns:pdfaProperty=\"http://www.aiim.org/pdfa/ns/property#\"><rdf:Bag><rdf:li rdf:parseType=\"Resource\">"
            + "<pdfaSchema:schema>Foo</pdfaSchema:schema><pdfaSchema:namespaceURI>http://example.com/foo/</pdfaSchema:namespaceURI>"
            + "<pdfaSchema:prefix>foo</pdfaSchema:prefix></rdf:li></rdf:Bag></pdfaExtension:schemas>"
        let file = withPacket { $0.replacingOccurrences(of: "<pdfaid:part>", with: "<foo:bar xmlns:foo=\"http://example.com/foo/\">1</foo:bar>" + schema + "<pdfaid:part>") }
        try StandardsKit.assertClean(file)
    }

    func test_thePredefinedSchemasNeedNoDeclaration() throws {
        let file = withPacket { $0.replacingOccurrences(of: "<pdfaid:part>", with: "<xmpMM:DocumentID xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\">uuid:1</xmpMM:DocumentID><pdfaid:part>") }
        try StandardsKit.assertClean(file)
    }

    func test_outputIntentsAreHeldToTheirRule() throws {
        let file = StandardsKit.compliant(extra: { pdf in
            pdf.obj(9, "<</Type /OutputIntent /S /GTS_PDFA1 /DestOutputProfile 7 0 R>>")
        }, intents: "/OutputIntents [9 0 R]")
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.message.contains("OutputConditionIdentifier") }
    }
}
