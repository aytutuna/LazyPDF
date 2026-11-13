using System.Text;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Arabic and Hebrew through the WPF text formatter, against fonts every Windows has.
public sealed class WpfShaperTests
{
    private static readonly SystemFontSource Source = new();

    private static (FontFile File, TrueTypeFont Font) Load(string family)
    {
        var file = Source.Find(family, FontStyles.Regular)!;
        return (file, TrueTypeFont.TryParse(file.Data, file.CollectionIndex)!);
    }

    private static IReadOnlyList<ShapedGlyph> Shape(FontFile file, string text, bool rtl = true) =>
        Source.Shape(text, file, rtl, null)!;

    private const string Meem = "\u0645", Reh = "\u0631", Hah = "\u062D", Beh = "\u0628", Alef = "\u0627", Lam = "\u0644", Fatha = "\u064E";

    [Fact]
    public void ArabicLettersTakeTheirJoinedForms()
    {
        var (file, font) = Load("Segoe UI");
        var glyphs = Shape(file, Meem + Reh + Hah + Beh + Alef);

        Assert.Equal(5, glyphs.Count);
        Assert.All(glyphs, g => Assert.InRange(g.Glyph, 1, font.GlyphCount - 1));
        // The last letter is drawn first on the left; the first letter is drawn on the right.
        Assert.Equal([4, 3, 2, 1, 0], glyphs.Select(g => g.Cluster));
        // The meem opens the word, so it is not the isolated glyph from the cmap.
        Assert.NotEqual(font.GlyphForCodePoint(0x0645), glyphs[^1].Glyph);
        Assert.NotEqual(font.GlyphForCodePoint(0x0627), glyphs[0].Glyph);
        Assert.All(glyphs, g => Assert.True(g.Advance > 0));
    }

    [Fact]
    public void LamAlefIsOneGlyphForTwoLetters()
    {
        var (file, font) = Load("Tahoma");
        var glyphs = Shape(file, Lam + Alef + Beh);

        Assert.Equal(2, glyphs.Count);
        Assert.Equal([2, 0], glyphs.Select(g => g.Cluster));
        Assert.Equal(font.GlyphForCodePoint(0xFEFB), glyphs[1].Glyph);
        Assert.All(glyphs, g => Assert.InRange(g.Glyph, 1, font.GlyphCount - 1));
    }

    [Fact]
    public void AMarkFollowsItsBaseInReadingOrderAndIsPlacedAbove()
    {
        var (file, _) = Load("Segoe UI");
        var glyphs = Shape(file, Beh + Fatha + Beh);

        // A mark belongs to the cluster of its base.
        Assert.Equal([2, 0, 0], glyphs.Select(g => g.Cluster));
        Assert.Equal(0, glyphs[1].Advance);
        Assert.NotEqual(0, glyphs[1].YOffset);
        Assert.Equal(0, glyphs[0].YOffset);
    }

    [Fact]
    public void AHebrewPointSitsOnItsLetter()
    {
        var (file, font) = Load("Segoe UI");
        var glyphs = Shape(file, "\u05D0\u05B8\u05D1");

        Assert.Equal(3, glyphs.Count);
        Assert.Equal([2, 0, 0], glyphs.Select(g => g.Cluster));
        // The point is drawn before the letter it belongs to, so it is moved right onto it.
        var point = glyphs[1];
        Assert.Equal(0, point.Advance);
        Assert.InRange(point.XOffset, 1, glyphs[2].Advance);
        Assert.Equal(font.GlyphForCodePoint(0x05D0), glyphs[2].Glyph);
    }

    [Fact]
    public void BracketsAreNotMirroredASecondTime()
    {
        var (file, font) = Load("Segoe UI");
        // Core hands over a right-to-left run with its brackets already swapped.
        var glyphs = Shape(file, ")" + Alef + "(");

        Assert.Equal(font.GlyphForCodePoint('('), glyphs[0].Glyph);
        Assert.Equal(font.GlyphForCodePoint(')'), glyphs[^1].Glyph);
    }

    [Fact]
    public void DirectionMarksAreDroppedAndClustersKeepTheirPlace()
    {
        var (file, _) = Load("Segoe UI");
        var glyphs = Shape(file, "\u200F" + Beh + Alef);

        Assert.Equal([2, 1], glyphs.Select(g => g.Cluster));
    }

    [Fact]
    public void ArabicLettersInALeftToRightRunAreLeftToCore()
    {
        var (file, _) = Load("Segoe UI");

        Assert.Null(Source.Shape(Beh + Alef, file, false, null));
    }

    [Fact]
    public void LatinTextIsLeftToCore()
    {
        var (file, _) = Load("Segoe UI");

        Assert.Null(Source.Shape("Hello 123", file, false, null));
    }

    [Fact]
    public void AFileThatDidNotComeFromTheSourceIsNotShaped()
    {
        var (file, _) = Load("Segoe UI");

        Assert.Null(Source.Shape(Beh + Alef, new FontFile(file.Data.ToArray(), file.CollectionIndex), true, null));
    }

    [Fact]
    public void ACharacterTheFontLacksIsLeftToCore()
    {
        // Arial has no Hebrew points of some scripts, but Thai is nowhere in it: WPF would switch fonts for it.
        var (file, _) = Load("Arial");

        Assert.Null(Source.Shape(Beh + "\u0E01", file, true, null));
    }

    [Fact]
    public void AVeryLongRunIsShapedWholeOrLeftToCore()
    {
        var (file, _) = Load("Segoe UI");
        string text = string.Concat(Enumerable.Repeat(Meem + Reh + Hah + Beh + Alef + " ", 6000));

        var glyphs = Source.Shape(text, file, true, null);

        if (glyphs is not null) Assert.Equal(text.Length - 1, glyphs.Max(g => g.Cluster));
    }

    [Fact]
    public void AnEmbeddedFontDrawsTheJoinedGlyphs()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var font = new PdfFontEmbedder(document, Source).Add("Tahoma", FontStyles.Regular, [Lam + Alef + Beh])!;
        var writer = new ContentWriter();
        writer.Show(font, Lam + Alef + Beh, 12);
        string content = Encoding.Latin1.GetString(writer.ToArray());

        Assert.Contains("ActualText", content);
        Assert.Equal(2, font.Encode(Lam + Alef + Beh).Length / 2);
    }
}
