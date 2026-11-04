using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfTextTests
{
    [Fact]
    public void AsciiStaysPdfDocEncoded()
    {
        Assert.Equal("Quarterly report"u8.ToArray(), PdfText.Encode("Quarterly report"));
    }

    [Fact]
    public void LatinTextFitsPdfDocEncoding()
    {
        // 0xE9 is e-acute in both PDFDocEncoding and Latin-1; the bullet and the euro sit in the 0x80 block.
        Assert.Equal([0x63, 0x61, 0x66, 0xE9, 0x20, 0x80, 0xA0], PdfText.Encode("caf\u00E9 \u2022\u20AC"));
        Assert.Equal("caf\u00E9 \u2022\u20AC", PdfText.Decode(PdfText.Encode("caf\u00E9 \u2022\u20AC")));
    }

    [Fact]
    public void OtherScriptsGoToUtf16WithMark()
    {
        var bytes = PdfText.Encode("T\u00FCrk\u00E7e \u011F");
        Assert.Equal([0xFE, 0xFF], bytes[..2]);
        Assert.Equal("T\u00FCrk\u00E7e \u011F", PdfText.Decode(bytes));
    }

    [Fact]
    public void SurrogatePairsSurvive()
    {
        string text = "mark \U0001F4D8";
        Assert.Equal(text, PdfText.Decode(PdfText.Encode(text)));
    }

    [Fact]
    public void DecodesUtf16LittleEndianAndUtf8WithMark()
    {
        Assert.Equal("ab\u0416", PdfText.Decode([0xFF, 0xFE, 0x61, 0, 0x62, 0, 0x16, 0x04]));
        Assert.Equal("ab\u0416", PdfText.Decode([0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("ab\u0416")]));
    }

    [Fact]
    public void LanguageEscapeIsDropped()
    {
        var bytes = new byte[] { 0xFE, 0xFF, 0, 0x1B, 0, (byte)'e', 0, (byte)'n', 0, 0x1B, 0, (byte)'H', 0, (byte)'i' };
        Assert.Equal("Hi", PdfText.Decode(bytes));
    }

    [Fact]
    public void UnassignedPdfDocCodesReadAsLatin1()
    {
        Assert.Equal("a\u007Fb", PdfText.Decode([0x61, 0x7F, 0x62]));
    }

    [Fact]
    public void ObjectIsHexWhenLiteralWouldNeedEscapes()
    {
        Assert.False(PdfText.ToObject("plain").IsHex);
        Assert.True(PdfText.ToObject("\u0416").IsHex);
    }

    [Fact]
    public void EmptyAndControlCharactersRoundTrip()
    {
        Assert.Equal("", PdfText.Decode(PdfText.Encode("")));
        Assert.Equal("a\tb\nc", PdfText.Decode(PdfText.Encode("a\tb\nc")));
        Assert.Equal("a\u0001b", PdfText.Decode(PdfText.Encode("a\u0001b")));
    }

    [Fact]
    public void ReadsStreamsAndStrings()
    {
        var document = PdfDocument.Open(TestPdf.Simple(1));
        Assert.Equal("BT /F1 12 Tf (1) Tj ET", PdfText.Read(document, document.Pages[0].Dictionary["Contents"]));
        Assert.Null(PdfText.Read(document, new PdfNumber(1)));
        Assert.Null(PdfText.Read(document, null));
    }
}
