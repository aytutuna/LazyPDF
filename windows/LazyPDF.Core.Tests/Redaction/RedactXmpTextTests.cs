using System.Diagnostics;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Words split over the text nodes and child elements of an element, names held in attributes, and a packet with very many parts to drop.
public class RedactXmpTextTests
{
    private const string Head = "<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>" +
        "<rdf:Description xmlns:xmpMM='http://ns.adobe.com/xap/1.0/mm/' xmlns:dc='http://purl.org/dc/elements/1.1/'>";
    private const string Tail = "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>";

    private static PdfDocument WithXmp(string body)
    {
        var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td (ZQXMARKER) Tj ET");
        document.Catalog["Metadata"] = document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") },
            Encoding.UTF8.GetBytes(Head + body + Tail)));
        return document;
    }

    private static RedactionResult Redact(PdfDocument document, bool change = false) =>
        new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"), new RedactionOptions { ChangeMetadata = change });

    [Theory]
    [InlineData("ZQX<![CDATA[MARKER]]>")]
    [InlineData("ZQX<!-- -->MARKER")]
    [InlineData("ZQX<b>MARKER</b>")]
    [InlineData("ZQX<b/>MARKER")]
    public void WordSplitOverTheNodesOfATitleIsFoundAndReplaced(string title)
    {
        using var document = WithXmp($"<dc:title>{title}</dc:title>");
        var result = Redact(document, true);
        Assert.False(RedactionKit.Holds(result.Bytes, "MARKER"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Fact]
    public void PhraseBrokenOverLinesInAPacketIsFoundAndReplaced()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 50 700 Td (ZQXFIRST ZQXSECOND) Tj ET");
        document.Catalog["Metadata"] = document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata"), ["Subtype"] = new PdfName("XML") },
            Encoding.UTF8.GetBytes(Head + "<dc:title>about ZQXFIRST\n      ZQXSECOND here</dc:title>" + Tail)));
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXFIRST ZQXSECOND"), new RedactionOptions { ChangeMetadata = true });
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXSECOND"));
        Assert.True(RedactionKit.Holds(result.Bytes, "about [redacted] here"));
    }

    [Fact]
    public void WordSplitOverTheNodesOfATitleIsReportedWhenNothingMayChange()
    {
        using var document = WithXmp("<dc:title>ZQX<![CDATA[MARKER]]></dc:title>");
        var result = Redact(document);
        Assert.False(result.Verification.IsClean);
    }

    [Fact]
    public void NamesOfPageCopiesHeldInAttributesAreDropped()
    {
        using var document = WithXmp("<dc:item xmpMM:DerivedFrom=\"ZQXDID\" xmpMM:ManagedFrom=\"ZQXMID\" dc:kept=\"yes\"/>");
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXDID"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMID"));
        Assert.True(RedactionKit.Holds(result.Bytes, "dc:kept"));
    }

    [Fact]
    public void VersionsAndAncestorsAreDropped()
    {
        using var document = WithXmp("<xmpMM:Versions><rdf:Seq><rdf:li><dc:comments>ZQXVERSION</dc:comments></rdf:li></rdf:Seq></xmpMM:Versions>" +
            "<photoshop:DocumentAncestors><rdf:Bag><rdf:li>ZQXANCESTOR</rdf:li></rdf:Bag></photoshop:DocumentAncestors>");
        var result = Redact(document);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXVERSION"));
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXANCESTOR"));
    }

    [Fact]
    public void PacketTheWriterRefusesIsEmptiedNotKept()
    {
        using var document = WithXmp("<dc:title>ZQXMARKER</dc:title><dc:x xmlns='a' xmlns:xmlns='b'/>");
        var result = Redact(document, true);
        Assert.False(RedactionKit.Holds(result.Bytes, "ZQXMARKER"));
        Assert.Contains(result.Report.Findings, f => f.Where == RedactionText.XmpUnreadable);
    }

    [Fact]
    public void ManyDroppedElementsAmongKeptOnesAreTakenOutInLinearTime()
    {
        using var document = WithXmp(string.Concat(Enumerable.Repeat("<dc:k/><xmpMM:History/>", 50_000)));
        var clock = Stopwatch.StartNew();
        var result = Redact(document);
        clock.Stop();
        Assert.False(RedactionKit.Holds(result.Bytes, "History"));
        Assert.True(RedactionKit.Holds(result.Bytes, "dc:k"));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10), $"took {clock.Elapsed}");
    }
}
