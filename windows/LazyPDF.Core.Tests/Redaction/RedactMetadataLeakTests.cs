using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactMetadataLeakTests
{
    private static PdfDocument TwoPages(Action<PdfDocument>? more = null)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <</Font <</F1 7 0 R>>>> /PieceInfo <</Illustrator <</Private <</AIPrivateData1 (ZQXPAGEPIECE)>>>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 7 0 R>>>>>>");
        pdf.Stream(5, "", "BT /F1 12 Tf 50 700 Td (other) Tj ET");
        pdf.Stream(6, "", "BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET");
        pdf.Obj(7, RedactionKit.Helvetica);
        var document = PdfDocument.Open(pdf.Finish());
        more?.Invoke(document);
        return document;
    }

    private static void SetPacket(PdfDocument document, byte[] data) =>
        document.Catalog["Metadata"] = document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") }, data));

    private static RedactionResult Redact(PdfDocument document, bool change = false) =>
        new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 1, "ZQXMARKER"), new RedactionOptions { ChangeMetadata = change });

    [Fact]
    public void PrivateDataOfAPageNobodyMarkedIsDropped()
    {
        using var document = TwoPages();
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEPIECE"));
    }

    [Fact]
    public void PageImagesAndDocumentIdsInOtherXmpWrappersAreDropped()
    {
        const string Xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>" +
            "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:xmp='http://ns.adobe.com/xap/1.0/' xmlns:xmpGImg='http://ns.adobe.com/xap/1.0/g/img/' xmpMM:OriginalDocumentID='ZQXORIG'>" +
            "<xmpMM:DocumentID>ZQXLINKID</xmpMM:DocumentID><xmpMM:InstanceID>ZQXINSTANCE</xmpMM:InstanceID>" +
            "<xmp:PageInfo><rdf:Alt><rdf:li rdf:parseType='Resource'><xmpGImg:image>ZQXPAGEIMAGE</xmpGImg:image></rdf:li></rdf:Alt></xmp:PageInfo>" +
            "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>";
        using var document = TwoPages(d => SetPacket(d, Encoding.UTF8.GetBytes(Xmp)));
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXLINKID"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXINSTANCE"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXORIG"));
    }

    [Fact]
    public void PacketInUtf16IsSearchedToo()
    {
        const string Xmp = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>" +
            "<rdf:Description xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:title><rdf:Alt><rdf:li xml:lang='x-default'>about ZQXMARKER</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>";
        using var document = TwoPages(d => SetPacket(d, [.. Encoding.Unicode.GetPreamble(), .. Encoding.Unicode.GetBytes(Xmp)]));
        var result = Redact(document, true);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMARKER"));
        Assert.Contains(result.Report.Findings, f => f.Where == "The XMP metadata");
    }

    [Fact]
    public void PacketThatCannotBeReadIsDropped()
    {
        using var document = TwoPages(d => SetPacket(d, Encoding.ASCII.GetBytes("ZQXBROKENPACKET")));
        var packet = (PdfStream)document.Resolve(document.Catalog["Metadata"])!;
        packet.Dictionary["Filter"] = new PdfName("FlateDecode");
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXBROKENPACKET"));
    }

    [Fact]
    public void IndirectStringIsReplacedWhenMetadataIsChanged()
    {
        using var document = TwoPages(d =>
        {
            var text = d.Add(PdfText.ToObject("about ZQXMARKER here"));
            var note = d.Add(new PdfDictionary { ["Type"] = new PdfName("Annot"), ["Subtype"] = new PdfName("Text"), ["Rect"] = new PdfArray([new PdfNumber(400), new PdfNumber(400), new PdfNumber(420), new PdfNumber(420)]), ["Contents"] = text });
            d.Pages[1].Dictionary["Annots"] = new PdfArray([note]);
        });
        var result = Redact(document, true);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMARKER"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }
}
