using System.Text;
using System.Text.RegularExpressions;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ShapingTests
{
    private static readonly byte[] Font = TrueTypeBuilder.BuildScript();

    private sealed class ScriptFonts : IFontSource
    {
        public List<string> Requests { get; } = [];

        public FontFile? Find(string family, FontStyles style)
        {
            Requests.Add(family);
            return new FontFile(Font);
        }
    }

    // Lam followed by alef is one glyph; every other character goes through the cmap.
    private sealed class LamAlefShaper : IShaper
    {
        public IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language)
        {
            var f = TrueTypeFont.TryParse(font.Data)!;
            var glyphs = new List<ShapedGlyph>();
            for (int i = 0; i < text.Length; i++)
            {
                if (text[i] == 'ل' && i + 1 < text.Length && text[i + 1] == 'ا')
                {
                    glyphs.Add(new ShapedGlyph(TrueTypeBuilder.LamAlef, 900, 0, 0, i++));
                    continue;
                }
                int gid = f.GlyphForCodePoint(text[i]);
                glyphs.Add(new ShapedGlyph(gid, f.GetAdvance(gid), 0, 0, i));
            }
            if (rightToLeft) glyphs.Reverse();
            return glyphs;
        }
    }

    // Raises every glyph and nudges it right, as a mark would be placed.
    private sealed class OffsetShaper : IShaper
    {
        public IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language) =>
            [.. new CmapShaper().Shape(text, font, rightToLeft, language)!.Select(g => g with { XOffset = 50, YOffset = 100, Advance = g.Advance + 20 })];
    }

    private sealed class ShaperAndFonts : IFontSource, IShaper
    {
        public int Calls { get; private set; }

        public FontFile? Find(string family, FontStyles style) => new(Font);

        public IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language)
        {
            Calls++;
            return new CmapShaper().Shape(text, font, rightToLeft, language);
        }
    }

    // The family asked for has no Hebrew; the script fallbacks give a font that has.
    private sealed class OnlySegoe : IFontSource
    {
        public List<string> Requests { get; } = [];

        public FontFile? Find(string family, FontStyles style)
        {
            Requests.Add(family);
            return family == "Calibri" ? new FontFile(TrueTypeBuilder.Build()) : new FontFile(Font);
        }
    }

    private static int G(int codePoint) => TrueTypeBuilder.Gid(codePoint);

    private static LineShaper Lines(IShaper? shaper = null) =>
        new(new FontFile(Font), shaper ?? new CmapShaper(), TrueTypeFont.TryParse(Font)!, null);

    private static string Visual(ShapedLine line) => string.Concat(line.Glyphs.Select(g => line.Text[g.Start..g.End]));

    private static PdfDocument Blank() => PdfDocument.Open(TestPdf.Simple(1));

    private static PdfDrawFont Embed(string text, IShaper? shaper = null) =>
        new PdfFontEmbedder(Blank(), new ScriptFonts(), shaper).Add("Script Sans", FontStyles.Regular, [text])!;

    private static string Content(Action<ContentWriter> write)
    {
        var writer = new ContentWriter();
        write(writer);
        return Encoding.Latin1.GetString(writer.ToArray());
    }

    [Fact]
    public void HebrewIsShownRightToLeft()
    {
        var line = Lines().Shape("אבג");
        Assert.Equal([G('ג'), G('ב'), G('א')], line.Glyphs.Select(g => g.Shaped.Glyph));
        Assert.True(line.RightToLeft);
        Assert.False(line.NeedsActualText);
        Assert.Equal(line.Glyphs.Sum(g => g.Shaped.Advance), line.Width);
    }

    [Fact]
    public void LongHebrewRunShapesInLinearTime()
    {
        var text = new string('א', 200_000);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var line = Lines().Shape(text);
        Assert.Equal(text.Length, line.Glyphs.Count);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), watch.Elapsed.ToString());
    }

    [Fact]
    public void LatinAndDigitsInsideHebrewKeepTheirOrder()
    {
        // Digits after Latin letters join the Latin run (W7).
        Assert.Equal("דג abc 12 בא", Visual(Lines().Shape("אב abc 12 גד")));
        Assert.Equal("דג 12 בא", Visual(Lines().Shape("אב 12 גד")));
    }

    [Fact]
    public void BracketsAreMirroredInRightToLeftText()
    {
        var line = Lines().Shape("אב (גד)");
        // The glyphs of ( and ) change places while the text of the line stays as typed.
        Assert.Equal([G('('), G('ד'), G('ג'), G(')'), G(' '), G('ב'), G('א')], line.Glyphs.Select(g => g.Shaped.Glyph));
        Assert.True(line.NeedsActualText);
    }

    [Fact]
    public void AMarkStaysAfterItsLetter()
    {
        var line = Lines().Shape("אבְ");
        Assert.Equal([G('ב'), G('ְ'), G('א')], line.Glyphs.Select(g => g.Shaped.Glyph));
    }

    [Fact]
    public void LatinTextIsLeftToRightAndNeedsNothing()
    {
        var line = Lines().Shape("abc 12");
        Assert.Equal("abc 12", Visual(line));
        Assert.False(line.RightToLeft);
        Assert.False(line.NeedsActualText);
    }

    [Fact]
    public void ABaseDirectionCanBeGiven()
    {
        Assert.Equal("!abc", Visual(Lines().Shape("abc!", 1)));
        Assert.Equal("abc!", Visual(Lines().Shape("abc!", 0)));
        Assert.Equal("בא!", Visual(Lines().Shape("אב!", 0)));
    }

    [Fact]
    public void ControlCharactersAndDirectionMarksTakeNoGlyph()
    {
        var line = Lines().Shape("‏א\tב‎");
        Assert.Equal([G('ב'), G('א')], line.Glyphs.Select(g => g.Shaped.Glyph));
    }

    [Fact]
    public void ARunCanBeShapedInTheDirectionTheLayoutResolved()
    {
        Assert.Equal([G('ג'), G('ב'), G('א')], Lines().ShapeRun("אבג", true).Glyphs.Select(g => g.Shaped.Glyph));
        Assert.Equal([G('א'), G('ב'), G('ג')], Lines().ShapeRun("אבג", false).Glyphs.Select(g => g.Shaped.Glyph));
    }

    [Fact]
    public void WrapBreaksOnLogicalTextAndKeepsTheParagraphDirection()
    {
        const string text = "אבג דהו abc זחט";
        var font = Embed(text);
        var lines = font.Wrap(text, 10, font.Width("אבג", 10) * 2.2);
        Assert.True(lines.Count >= 2);
        // A line that starts with Latin still belongs to a right-to-left paragraph.
        Assert.All(lines, l => Assert.True(font.IsRightToLeft(l)));
        Assert.Equal(text, string.Join(" ", lines.Select(l => l.Trim('‏', ' '))));
    }

    [Fact]
    public void WrapOfPlainTextIsUntouched()
    {
        var font = Embed("abc def ghi");
        Assert.Equal(["abc def", "ghi"], font.Wrap("abc def ghi", 10, font.Width("abc def", 10) + 1));
    }

    [Fact]
    public void WrapGivenADirectionMarksEveryLineThatDiffers()
    {
        var font = Embed("abc def");
        Assert.Equal(["‏abc", "‏def"], font.Wrap("abc def", 10, font.Width("abc", 10) + 1, rightToLeft: true));
    }

    [Fact]
    public void ForcedRightToLeftStillDrawsTheBracketsOfPlainText()
    {
        var font = Embed("a (b)");
        var codes = font.Encode("‏a (b)").Chunk(2).Select(c => c[0] << 8 | c[1]).ToArray();
        Assert.Equal(5, codes.Length);
        Assert.DoesNotContain(0, codes);
    }

    [Fact]
    public void ShowWritesHebrewInDisplayOrderWithoutActualText()
    {
        var font = Embed("אבג");
        string content = Content(w => w.Show(font, "אבג", 12));
        Assert.DoesNotContain("ActualText", content);
        Assert.Equal(Convert.ToHexString(font.Encode("אבג")), Regex.Match(content, "<([0-9A-F]+)> Tj").Groups[1].Value);
        Assert.Equal(6, font.Encode("אבג").Length);
        Assert.NotEqual(font.Encode("גבא"), font.Encode("אבג"));
    }

    [Fact]
    public void ALigatureGetsAToUnicodeEntryOfTwoCodePointsAndActualText()
    {
        const string text = "لا ب";
        var document = Blank();
        var font = new PdfFontEmbedder(document, new ScriptFonts(), new LamAlefShaper()).Add("Script Sans", FontStyles.Regular, [text])!;

        var line = Lines(new LamAlefShaper()).Shape(text);
        Assert.Equal(3, line.Glyphs.Count);
        Assert.True(line.NeedsActualText);

        string content = Content(w => w.Show(font, text, 12));
        Assert.Contains("/Span <</ActualText <FEFF0644062700200628>>> BDC", content);
        Assert.EndsWith("EMC\n", content);

        // The ligature glyph reads back as both letters through the ToUnicode map.
        var page = document.Pages[0];
        string name = ContentResources.Add(document, ContentResources.ForEdit(document, page), "Font", font.Reference, "F");
        page.Dictionary["Contents"] = document.Add(new PdfStream(new PdfDictionary(), new ContentWriter().BeginText().Font(name, 12).Show(font, text, 12).EndText().ToArray()));
        using var reopened = PdfDocument.Open(document.SaveRewrite());
        var fonts = reopened.Dict(reopened.Pages[0].Resources, "Font")!;
        var ours = PdfFont.Get(reopened, (PdfDictionary)reopened.Resolve(fonts.Entries[0].Value)!);
        Assert.Equal("لا", ours.ToText(font.Encode("لا")));
    }

    [Fact]
    public void OffsetsAndAdvancesBecomeTjAdjustmentsAndRises()
    {
        var font = Embed("ab", new OffsetShaper());
        string content = Content(w => w.Show(font, "ab", 10));
        // Raised 100/1000 of 10 points and back to 0 afterwards; each glyph is drawn 50 to the right, and the pen
        // is then put where advance + 20 says (30 back, less the 50 of the next glyph).
        Assert.StartsWith("1 Ts\n[-50 <", content);
        Assert.Contains("> -20 <", content);
        Assert.EndsWith("0 Ts\n", content);
    }

    [Fact]
    public void TheFontSourceCanBeTheShaperToo()
    {
        var source = new ShaperAndFonts();
        var font = new PdfFontEmbedder(Blank(), source).Add("Script Sans", FontStyles.Regular, ["ab"])!;
        Assert.Equal(4, font.Encode("ab").Length);
        Assert.True(source.Calls > 0);
    }

    [Fact]
    public void HebrewFallsBackToAFontThatHasIt()
    {
        var source = new OnlySegoe();
        var font = new PdfFontEmbedder(Blank(), source).Add("Calibri", FontStyles.Regular, ["אב"])!;
        Assert.Empty(font.Missing);
        Assert.Equal(["Calibri", "Segoe UI"], source.Requests);
    }

    [Fact]
    public void LatinOnlyTextAsksForTheFamilyAlone()
    {
        var source = new ScriptFonts();
        new PdfFontEmbedder(Blank(), source).Add("Script Sans", FontStyles.Regular, ["abc"]);
        Assert.Equal(["Script Sans"], source.Requests);
    }

    [Fact]
    public void ARightToLeftParagraphIsLaidOutInDisplayOrder()
    {
        const string text = "אבג דהו";
        var font = Embed(text);
        var lines = TextLayout.Layout([[new TextRun(text, TextFormat.Default)]], 1000, TextFormat.Default, _ => font);
        var line = Assert.Single(lines);
        Assert.True(line.RightToLeft);
        Assert.All(line.Pieces, p => Assert.True(p.RightToLeft));
        // The second word is on the left.
        Assert.Equal(["דהו", "אבג "], line.Pieces.Select(p => p.Text));
    }

    [Fact]
    public void ALatinParagraphKeepsItsPieces()
    {
        var font = Embed("abc def");
        var lines = TextLayout.Layout([[new TextRun("abc def", TextFormat.Default)]], 1000, TextFormat.Default, _ => font);
        var line = Assert.Single(lines);
        Assert.False(line.RightToLeft);
        Assert.Equal(["abc ", "def"], line.Pieces.Select(p => p.Text));
    }
}
