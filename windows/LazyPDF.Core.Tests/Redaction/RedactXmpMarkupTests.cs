using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The word in the markup of an XMP packet: an instruction, the address of a namespace, the name of an element. None of them is
// text that can be replaced, so the packet is emptied and reported, and with nothing to change it is found by the bytes.
public class RedactXmpMarkupTests
{
    private const string Word = "ZQXMARKER";

    private static RedactionResult Redact(string body, byte[]? prefix = null, bool change = true)
    {
        var packet = (prefix ?? []).Concat(Encoding.UTF8.GetBytes("<?xpacket begin='' id='W5M0MpCehiHzreSzNTczkc9d'?><x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
            + "<rdf:Description rdf:about=''>" + body + "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end='w'?>")).ToArray();
        using var document = RedactionKit.Page($"BT /F1 12 Tf 100 100 Td ({Word}) Tj ET", "", pdf => pdf.Stream(9, "/Type /Metadata /Subtype /XML", packet));
        document.Catalog["Metadata"] = new PdfReference(9, 0);
        return new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, Word), new RedactionOptions { ChangeMetadata = change });
    }

    [Theory]
    [InlineData("<?note ZQXMARKER was here?>")]
    [InlineData("<dc:title xmlns:dc='http://purl.org/dc/elements/1.1/ZQXMARKER'>Report</dc:title>")]
    [InlineData("<ZQXMARKER>Report</ZQXMARKER>")]
    [InlineData("<dc:title ZQXMARKER='x' xmlns:dc='http://purl.org/dc/elements/1.1/'>Report</dc:title>")]
    public void MarkupHoldingTheWordEmptiesThePacket(string body)
    {
        var result = Redact(body);
        Assert.Contains(result.Report.Findings, f => f.Where == RedactionText.XmpUnreadable && f.Changed);
        Assert.False(RedactionKit.Holds(result.Bytes, Word));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }

    [Theory]
    [InlineData("<?note ZQXMARKER was here?>")]
    [InlineData("<ZQXMARKER>Report</ZQXMARKER>")]
    public void MarkupHoldingTheWordIsFoundWhenNothingMayChange(string body)
    {
        var result = Redact(body, change: false);
        Assert.Contains(result.Report.Findings, f => f.Where == "The XMP metadata" && !f.Changed);
        Assert.False(result.Verification.IsClean);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void SecondByteOrderMarkEmptiesThePacket(bool change)
    {
        var result = Redact($"<?note {Word}?><dc:title xmlns:dc='http://purl.org/dc/elements/1.1/'>{Word}</dc:title>", [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF], change);
        Assert.Contains(result.Report.Findings, f => f.Where == RedactionText.XmpUnreadable);
        Assert.False(RedactionKit.Holds(result.Bytes, Word));
    }

    [Fact]
    public void VerifySearchesTheBytesOfAPacketAsWellAsItsText()
    {
        using var document = RedactionKit.Page("BT ET");
        document.Catalog["Metadata"] = document.Add(new PdfStream(new PdfDictionary { ["Type"] = new PdfName("Metadata") },
            Encoding.UTF8.GetBytes($"<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><?note {Word}?></x:xmpmeta>")));
        Assert.False(PdfRedactor.Verify(document.SaveRewrite(), [], [Word]).IsClean);
    }
}
