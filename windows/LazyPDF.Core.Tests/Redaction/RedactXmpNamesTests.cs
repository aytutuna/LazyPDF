using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// XMP found by what it is and not by how it is spelled, packets held by direct dictionaries, wide encodings with a mark, and
// the other places removed words can hide.
public class RedactXmpNamesTests
{
    private const string Head = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>" +
        "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:stRef='http://ns.adobe.com/xap/1.0/sType/ResourceRef#' xmlns:dc='http://purl.org/dc/elements/1.1/' " +
        "xmlns:x-mp='urn:mp' xmlns:x-g='urn:g' xmlns:xmp='http://ns.adobe.com/xap/1.0/'>";
    private const string Tail = "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>";

    private static PdfDocument Open(string text = "ZQXMARKER", Action<PdfDocument>? more = null)
    {
        var document = RedactionKit.Page($"BT /F1 12 Tf 50 700 Td ({text}) Tj ET");
        more?.Invoke(document);
        return document;
    }

    private static PdfReference Packet(PdfDocument document, byte[] data) =>
        document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") }, data));

    private static RedactionResult Redact(PdfDocument document, string word = "ZQXMARKER", bool change = false) =>
        new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, word), new RedactionOptions { ChangeMetadata = change });

    private static RedactionResult WithXmp(string body)
    {
        using var document = Open(more: d => d.Catalog["Metadata"] = Packet(d, Encoding.UTF8.GetBytes(Head + body + Tail)));
        return Redact(document);
    }

    [Fact]
    public void ThumbnailUnderAPrefixWithAHyphenIsDropped()
    {
        var result = WithXmp("<x-mp:Thumbnails><rdf:Alt><rdf:li><x-g:image>ZQXPAGEIMAGE</x-g:image></rdf:li></rdf:Alt></x-mp:Thumbnails>");
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
    }

    [Fact]
    public void ThumbnailInADefaultNamespaceIsDropped()
    {
        var result = WithXmp("<Thumbnails xmlns='urn:t'><image xmlns='urn:i'>ZQXPAGEIMAGE</image></Thumbnails>");
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
    }

    [Fact]
    public void IdsAreFoundWhateverTheCaseAndTheElementThatHoldsThem()
    {
        var result = WithXmp("<xmpMM:ManagedFrom stRef:documentID=\"ZQXDID\" stRef:instanceID=\"ZQXIID\"/><xmpMM:RenditionOf><rdf:Description stRef:instanceID=\"ZQXRID\"/></xmpMM:RenditionOf>");
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXDID"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXIID"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXRID"));
    }

    [Fact]
    public void AttributeValueWithAGreaterThanSignDoesNotEndTheElementEarly()
    {
        var result = WithXmp("<xmpMM:DerivedFrom stRef:filePath=\"a>b\" stRef:documentID=\"ZQXDID\"/>");
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXDID"));
    }

    [Fact]
    public void PacketNamedByADirectDictionaryOfAnObjectIsVisited()
    {
        string xmp = Head + "<xmp:Thumbnails><rdf:Alt><rdf:li>ZQXPAGEIMAGE</rdf:li></rdf:Alt></xmp:Thumbnails>" + Tail;
        using var document = Open(more: d => d.Pages[0].Dictionary["Group"] = new PdfDictionary
        {
            ["S"] = new PdfName("Transparency"),
            ["Metadata"] = d.Add(new PdfStream(new PdfDictionary(), Encoding.UTF8.GetBytes(xmp))),
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXPAGEIMAGE"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void WidePacketWithItsMarkAtTheFirstByteIsRead(bool bigEndian)
    {
        var encoding = new UTF32Encoding(bigEndian, true);
        byte[] data = [.. encoding.GetPreamble(), .. encoding.GetBytes(Head + "<xmpMM:History>ZQXHISTORY</xmpMM:History>" + Tail)];
        using var document = Open(more: d => d.Catalog["Metadata"] = Packet(d, data));
        var result = Redact(document);
        Assert.DoesNotContain(Encoding.Latin1.GetString(encoding.GetBytes("ZQXHISTORY")), RedactionKit.Everything(result.Bytes));
    }

    [Fact]
    public void CharacterReferenceDoesNotHideRemovedTextFromTheSearch()
    {
        string xmp = Head + "<dc:title>J&#97;ne Doe</dc:title>" + Tail;
        using var document = Open("Jane Doe", d => d.Catalog["Metadata"] = Packet(d, Encoding.UTF8.GetBytes(xmp)));
        var result = Redact(document, "Jane Doe", change: true);
        Assert.DoesNotContain("J&#97;ne", RedactionKit.Everything(result.Bytes));
        Assert.Contains(result.Report.Findings, f => f.Where == "The XMP metadata" && f.Changed);
    }

    [Fact]
    public void VerifyFindsRemovedTextBehindACharacterReference()
    {
        string xmp = Head + "<dc:title>J&#97;ne Doe</dc:title>" + Tail;
        using var document = Open("Jane Doe", d => d.Catalog["Metadata"] = Packet(d, Encoding.UTF8.GetBytes(xmp)));
        var problems = PdfRedactor.Verify(document.SaveRewrite(), [], ["Jane Doe"]).Problems;
        Assert.NotEmpty(problems);
    }

    [Fact]
    public void PacketThatIsNotXmlIsEmptiedAtOnce()
    {
        byte[] data = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("<a:image </", 30_000)));
        using var document = Open(more: d => d.Catalog["Metadata"] = Packet(d, data));
        var result = Redact(document);
        Assert.Contains(result.Report.Findings, f => f.Where == RedactionText.XmpUnreadable);
    }

    [Fact]
    public void PacketOverTheSizeLimitIsEmptiedAndReported()
    {
        byte[] data = new byte[(16 << 20) + 1];
        Array.Fill(data, (byte)' ');
        using var document = Open(more: d => d.Catalog["Metadata"] = Packet(d, data));
        var result = Redact(document);
        Assert.Contains(result.Report.Findings, f => f.Where == RedactionText.XmpUnreadable);
        Assert.True(result.Bytes.Length < 1 << 20);
    }

    [Fact]
    public void NameThatHoldsRemovedWordsIsRenamed()
    {
        using var document = Open("Jane Doe", d => d.Catalog["Dests"] = new PdfDictionary { ["Jane Doe"] = new PdfArray([new PdfName("Fit")]) });
        var result = Redact(document, "Jane Doe", change: true);
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.DoesNotContain(output.Dict(output.Catalog, "Dests")!.Entries, e => e.Key.Contains("Jane"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void VerifyFindsRemovedTextHeldInAName()
    {
        using var document = Open("Jane Doe", d => d.Catalog["Dests"] = new PdfDictionary { ["Jane Doe"] = new PdfArray([new PdfName("Fit")]) });
        var problems = PdfRedactor.Verify(document.SaveRewrite(), [], ["Jane Doe"]).Problems;
        Assert.NotEmpty(problems);
    }

    [Fact]
    public void NamesTheFormatDefinesAreLeftWhateverTheWordsAre()
    {
        using var document = Open("Page Type", d => d.Catalog["Dests"] = new PdfDictionary { ["Fit"] = new PdfName("Type") });
        var result = Redact(document, "Page Type");
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.Equal("Page", output.Name(output.Pages[0].Dictionary, "Type"));
    }

    [Fact]
    public void FileAttachedToThePageDoesNotStay()
    {
        using var document = Open(more: d =>
        {
            var file = d.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("EmbeddedFile") }, Encoding.Latin1.GetBytes("ZQXATTACHEDSOURCE")));
            d.Pages[0].Dictionary["AF"] = new PdfArray([new PdfDictionary
            {
                ["Type"] = new PdfName("Filespec"),
                ["EF"] = new PdfDictionary { ["F"] = file },
            }]);
        });
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXATTACHEDSOURCE"));
    }
}
