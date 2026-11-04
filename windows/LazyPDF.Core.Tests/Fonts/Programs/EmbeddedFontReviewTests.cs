using Xunit;

namespace LazyPDF.Core.Tests;

public class EmbeddedFontReviewTests
{
    private static byte[] Arial()
    {
        var data = ProgramFonts.Windows("arial.ttf");
        Assert.True(data is not null, "arial.ttf is not installed; this test needs it");
        return data;
    }

    [Fact]
    public void EncodeSkipsControlCharactersLikeWidth()
    {
        var font = EmbeddedFontBuilder.Build(Arial(), ["a\tb"], out _)!;
        Assert.Equal(4, font.Encode("a\tb").Length);
    }

    [Fact]
    public void NotdefAdvanceIsWrittenWhenCharactersAreMissing()
    {
        var data = Arial();
        var font = EmbeddedFontBuilder.Build(data, ["a\u4E2D"], out _)!;
        var source = TrueTypeFont.TryParse(data)!;
        var first = font.Widths.First(r => r.FirstCid == 0);
        Assert.Equal((int)Math.Round(source.GetAdvance(0) * 1000.0 / source.UnitsPerEm), first.Widths[0]);
    }
}
