using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Page copies and ids in the forms XMP writers use besides the one Adobe tools write most: attributes, self-closed elements, other prefixes and encodings.
public class RedactXmpShapeTests
{
    private const string Head = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>" +
        "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:stRef='http://ns.adobe.com/xap/1.0/sType/ResourceRef#' xmlns:xmpGImg='http://ns.adobe.com/xap/1.0/g/img/' xmlns:zz='urn:zz'>";
    private const string Tail = "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>";

    private static PdfDocument TwoPages(Action<PdfDocument> more)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Stream(5, "", "BT /F1 12 Tf 50 700 Td (other) Tj ET");
        pdf.Stream(6, "", "BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET");
        pdf.Obj(7, RedactionKit.Helvetica);
        var document = PdfDocument.Open(pdf.Finish());
        more(document);
        return document;
    }

    private static PdfReference Packet(PdfDocument document, byte[] data) =>
        document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") }, data));

    private static RedactionResult Redact(PdfDocument document) =>
        new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 1, "ZQXMARKER"));

    private static string Wrap(string body) => Head + body + Tail;

    [Fact]
    public void PageImageHeldInAttributesIsDropped()
    {
        string xmp = Wrap("<zz:PageImages><rdf:Alt><rdf:li xmpGImg:format=\"JPEG\" xmpGImg:image=\"ZQXPAGEIMAGE\"/></rdf:Alt></zz:PageImages>");
        using var document = TwoPages(d => d.Catalog["Metadata"] = Packet(d, Encoding.UTF8.GetBytes(xmp)));
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
    }

    [Fact]
    public void SelfClosedDerivedFromAndOtherPrefixedIdsAreDropped()
    {
        string xmp = Wrap("<xmpMM:DerivedFrom stRef:instanceID=\"ZQXIID\" stRef:documentID=\"ZQXDID\"/><xapMM:DocumentID>ZQXOLDID</xapMM:DocumentID><mm:InstanceID xmlns:mm='http://ns.adobe.com/xap/1.0/mm/'>ZQXREBOUND</mm:InstanceID>");
        using var document = TwoPages(d => d.Catalog["Metadata"] = Packet(d, Encoding.UTF8.GetBytes(xmp)));
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXIID"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXDID"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXOLDID"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXREBOUND"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Utf16PacketWithTheMarkInsideTheWrapperIsRead(bool bigEndian)
    {
        string xmp = Wrap("<xmp:Thumbnails xmlns:xmp='http://ns.adobe.com/xap/1.0/'><rdf:Alt><rdf:li><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>")
            .Replace("begin=''", "begin='﻿'");
        var encoding = bigEndian ? Encoding.BigEndianUnicode : new UnicodeEncoding(false, false);
        using var document = TwoPages(d => d.Catalog["Metadata"] = Packet(d, encoding.GetBytes(xmp)));
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
    }

    [Fact]
    public void PacketOfAPageHeldOnlyBySubtypeIsVisited()
    {
        string xmp = Wrap("<xmp:Thumbnails xmlns:xmp='http://ns.adobe.com/xap/1.0/'><rdf:Alt><rdf:li><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>");
        using var document = TwoPages(d =>
        {
            var packet = d.Add(new PdfStream(new PdfDictionary { ["Subtype"] = new PdfName("XML") }, Encoding.UTF8.GetBytes(xmp)));
            d.Pages[0].Dictionary["Metadata"] = packet;
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
    }

    [Fact]
    public void PacketNamedOnlyByAMetadataKeyIsVisited()
    {
        string xmp = Wrap("<xmp:Thumbnails xmlns:xmp='http://ns.adobe.com/xap/1.0/'><rdf:Alt><rdf:li><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:Thumbnails>");
        using var document = TwoPages(d => d.Pages[0].Dictionary["Metadata"] = d.Add(new PdfStream(new PdfDictionary(), Encoding.UTF8.GetBytes(xmp))));
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
    }
}
