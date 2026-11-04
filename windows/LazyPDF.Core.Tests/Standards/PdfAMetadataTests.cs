using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAMetadataTests
{
    private static byte[] WithPacket(Func<string, string> edit, PdfALevel level = PdfALevel.A2b) =>
        StandardsKit.Compliant(level, xmp: edit(StandardsKit.Packet(level)));

    [Fact]
    public void AFileWithoutMetadataIsReported()
    {
        byte[] file = StandardsKit.Edited(StandardsKit.Compliant(), d => d.Catalog.Remove("Metadata"));
        Assert.Contains("6.6.2.1", StandardsKit.Clauses(file));
        Assert.Contains("6.7.2", StandardsKit.Clauses(file, PdfALevel.A1b));
    }

    [Fact]
    public void APacketThatIsNotWellFormedIsReported()
    {
        Assert.Contains(StandardsKit.Check(WithPacket(p => p.Replace("</rdf:RDF>", ""))).Issues, i => i.Clause == "6.6.2.1" && i.Message.Contains("well-formed"));
        Assert.Contains(StandardsKit.Check(WithPacket(_ => "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>")).Issues, i => i.Message.Contains("rdf:RDF"));
    }

    [Fact]
    public void ADoctypeInThePacketIsNotRead()
    {
        byte[] file = WithPacket(p => "<!DOCTYPE x [<!ENTITY a \"b\">]>" + p);
        Assert.Contains("6.6.2.1", StandardsKit.Clauses(file));
    }

    [Fact]
    public void TheIdentificationHasToNameThePartAndLevel()
    {
        Assert.Contains("6.6.4", StandardsKit.Clauses(WithPacket(p => p.Replace("<pdfaid:part>2</pdfaid:part>", ""))));
        Assert.Contains(StandardsKit.Check(WithPacket(p => p.Replace("<pdfaid:part>2<", "<pdfaid:part>1<"))).Issues, i => i.Message.Contains("part 1"));
        Assert.Contains("6.6.4", StandardsKit.Clauses(WithPacket(p => p.Replace("<pdfaid:conformance>B<", "<pdfaid:conformance>X<"))));
        Assert.Contains("6.7.11", StandardsKit.Clauses(WithPacket(p => p.Replace("<pdfaid:part>2<", "<pdfaid:part>3<"), PdfALevel.A2b), PdfALevel.A1b));
    }

    [Fact]
    public void LevelUAsksForUAndLevelBAcceptsBoth()
    {
        byte[] b = StandardsKit.Compliant(PdfALevel.A2b);
        byte[] u = StandardsKit.Compliant(PdfALevel.A2u);
        Assert.Contains("6.6.4", StandardsKit.Clauses(b, PdfALevel.A2u));
        StandardsKit.AssertClean(u, PdfALevel.A2b);
        StandardsKit.AssertClean(u, PdfALevel.A2u);
    }

    [Fact]
    public void Part4NeedsTheRevisionAndNoLevel()
    {
        Assert.Contains("6.6.4", StandardsKit.Clauses(WithPacket(p => p.Replace("<pdfaid:rev>2020</pdfaid:rev>", ""), PdfALevel.A4), PdfALevel.A4));
        Assert.Contains("6.1.3", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A4, info: "<</Title (x) /CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)>>"), PdfALevel.A4));
    }

    [Fact]
    public void InfoEntriesHaveToAgreeWithTheXmp()
    {
        byte[] title = StandardsKit.Compliant(info: "<</Title (Other) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)>>");
        Assert.Contains(StandardsKit.Check(title).Issues, i => i.Clause == "6.6.2.3" && i.Message.Contains("/Title"));
        Assert.Contains("6.7.3", StandardsKit.Clauses(title, PdfALevel.A1b));

        byte[] date = StandardsKit.Compliant(info: "<</Title (Title) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103001Z) /ModDate (D:20260304103000Z)>>");
        Assert.Contains(StandardsKit.Check(date).Issues, i => i.Message.Contains("/CreationDate"));

        byte[] extra = StandardsKit.Compliant(info: "<</Title (Title) /Author (Someone) /Creator (Test) /Producer (Test) /CreationDate (D:20260304103000Z) /ModDate (D:20260304103000Z)>>");
        Assert.Contains(StandardsKit.Check(extra).Issues, i => i.Message.Contains("/Author"));
    }

    [Fact]
    public void ADateInAnotherZoneIsTheSameMoment()
    {
        byte[] file = StandardsKit.Compliant(info: "<</Title (Title) /Creator (Test) /Producer (Test) /CreationDate (D:20260304123000+02'00') /ModDate (D:20260304123000+02'00')>>");
        StandardsKit.AssertClean(file);
    }

    private const string Foo = " xmlns:foo=\"http://example.com/foo/\"";

    [Fact]
    public void PropertiesOfAnUnknownSchemaNeedAnExtensionSchema()
    {
        byte[] file = WithPacket(p => p.Replace("<pdfaid:part>", "<foo:bar xmlns:foo=\"http://example.com/foo/\">1</foo:bar><pdfaid:part>"));
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.6.2.3.1" && i.Message.Contains("http://example.com/foo/"));
        Assert.Contains("6.7.8", StandardsKit.Clauses(file, PdfALevel.A1b));
    }

    [Fact]
    public void ADeclaredExtensionSchemaPasses()
    {
        string schema = "<pdfaExtension:schemas xmlns:pdfaExtension=\"http://www.aiim.org/pdfa/ns/extension/\" xmlns:pdfaSchema=\"http://www.aiim.org/pdfa/ns/schema#\" " +
                        "xmlns:pdfaProperty=\"http://www.aiim.org/pdfa/ns/property#\"><rdf:Bag><rdf:li rdf:parseType=\"Resource\">" +
                        "<pdfaSchema:schema>Foo</pdfaSchema:schema><pdfaSchema:namespaceURI>http://example.com/foo/</pdfaSchema:namespaceURI>" +
                        "<pdfaSchema:prefix>foo</pdfaSchema:prefix></rdf:li></rdf:Bag></pdfaExtension:schemas>";
        byte[] file = WithPacket(p => p.Replace("<pdfaid:part>", "<foo:bar xmlns:foo=\"http://example.com/foo/\">1</foo:bar>" + schema + "<pdfaid:part>"));
        StandardsKit.AssertClean(file);
    }

    [Fact]
    public void ThePredefinedSchemasNeedNoDeclaration()
    {
        byte[] file = WithPacket(p => p.Replace("<pdfaid:part>", "<xmpMM:DocumentID xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\">uuid:1</xmpMM:DocumentID><pdfaid:part>"));
        StandardsKit.AssertClean(file);
    }

    [Fact]
    public void OutputIntentsAreHeldToTheirRule()
    {
        byte[] file = StandardsKit.Compliant(intents: "/OutputIntents [9 0 R]", extra: pdf => pdf.Obj(9, "<</Type /OutputIntent /S /GTS_PDFA1 /DestOutputProfile 7 0 R>>"));
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Message.Contains("OutputConditionIdentifier"));
    }
}
