using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SanitizeHiddenTextTests
{
    private static int Hidden(string content)
    {
        byte[] file = OptimizeKit.Build(content, "/Font <</F1 5 0 R>> /ExtGState <</GS0 <</ca 0>>>>", pdf =>
        {
            pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        });
        using var document = PdfDocument.Open(file);
        return SanitizeKit.Count(new PdfSanitizer(document).Scan(), SanitizeItem.HiddenText);
    }

    [Fact]
    public void TextPaintedWithZeroOpacityIsHidden() =>
        Assert.Equal(1, Hidden("/GS0 gs BT /F1 12 Tf 10 100 Td (GHOST) Tj ET"));

    [Fact]
    public void TextWithTheOpacityRestoredIsNot() =>
        Assert.Equal(0, Hidden("q /GS0 gs Q BT /F1 12 Tf 10 100 Td (SHOWN) Tj ET"));

    [Fact]
    public void TextOutsideThePageIsHidden() =>
        Assert.Equal(1, Hidden("BT /F1 12 Tf -5000 100 Td (AWAY) Tj ET BT /F1 12 Tf 10 100 Td (HERE) Tj ET"));

    [Fact]
    public void TextCutAwayByAClipIsHidden() =>
        Assert.Equal(1, Hidden("q 0 0 20 20 re W n BT /F1 12 Tf 100 100 Td (CLIPPED) Tj ET Q"));

    [Fact]
    public void TextUnderAClipThatMissesThePageIsHidden() =>
        Assert.Equal(1, Hidden("q 300 300 10 10 re W n BT /F1 12 Tf 0 0 Td (SECRET) Tj ET Q"));

    [Fact]
    public void TextTooSmallToReadIsHidden() =>
        Assert.Equal(1, Hidden("BT /F1 0.3 Tf 10 100 Td (TINY) Tj ET BT /F1 8 Tf 10 50 Td (SMALL) Tj ET"));

    [Theory]
    [InlineData("/GS0 gs BT 4 Tr /F1 12 Tf 10 100 Td (GHOST) Tj ET")]
    [InlineData("BT 4 Tr /F1 12 Tf -5000 100 Td (AWAY) Tj ET")]
    [InlineData("BT 6 Tr /F1 12 Tf -5000 100 Td (AWAY) Tj ET")]
    public void TextThatAlsoClipsIsJudgedLikeTextThatDoesNot(string content) => Assert.Equal(1, Hidden(content));

    [Fact]
    public void ReadableTextOnThePageIsNotHidden() =>
        Assert.Equal(0, Hidden("BT /F1 12 Tf 10 100 Td (PLAIN) Tj ET"));
}
