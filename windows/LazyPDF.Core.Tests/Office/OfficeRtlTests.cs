using System.Text;
using LazyPDF.Core.Office;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OfficeRtlTests
{
    // Every family is the script font; each family gets a copy of its own, so that the layout keeps the names apart.
    private sealed class ScriptFont(byte[] data) : IFontSource
    {
        private readonly Dictionary<string, FontFile> _files = [];

        public FontFile? Find(string family, FontStyles style)
        {
            if (!_files.TryGetValue(family, out var file)) _files[family] = file = new FontFile((byte[])data.Clone());
            return file;
        }
    }

    // Raises and nudges every glyph, as a platform shaper places marks.
    private sealed class OffsetScriptFont(byte[] data) : IFontSource, IShaper
    {
        public FontFile? Find(string family, FontStyles style) => new(data);

        public IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language) =>
            [.. new CmapShaper().Shape(text, font, rightToLeft, language)!.Select(g => g with { XOffset = 50, YOffset = 100 })];
    }

    // Joined forms are narrower than the isolated letters.
    private sealed class NarrowScriptFont(byte[] data) : IFontSource, IShaper
    {
        public FontFile? Find(string family, FontStyles style) => new(data);

        public IReadOnlyList<ShapedGlyph>? Shape(string text, FontFile font, bool rightToLeft, string? language) =>
            [.. new CmapShaper().Shape(text, font, rightToLeft, language)!.Select(g => g with { Advance = g.Advance / 2 })];
    }

    [Fact]
    public void ArabicIsMeasuredWithTheAdvancesTheShaperDraws()
    {
        var data = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "shaping", "script.ttf"));
        var fonts = new OfficeFontSource(new NarrowScriptFont(data), null);
        var layout = new Paginator(Document(Paragraph("ابلم", rtl: true, LayoutAlign.Right)), new LayoutFonts(fonts), default).Run();
        var text = Assert.Single(layout.Pages[0].Boxes.OfType<PlacedText>());
        var face = new LayoutFonts(fonts).Find(OfficeFontSource.DefaultFamily, FontStyles.Regular)!;
        double isolated = text.Text.EnumerateRunes().Sum(r => face.Advance(r.Value)) * text.Size;
        Assert.Equal(180 - isolated / 2, text.X, 0.01);
    }

    private static string Drawn(LayoutAlign align, string text)
    {
        var data = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "shaping", "script.ttf"));
        var contents = new List<byte[]>();
        OfficePdfWriter.Create(Document(Paragraph(text, rtl: false, align)), new OfficeFontSource(new OffsetScriptFont(data), null), default, contents);
        return Encoding.Latin1.GetString(contents[0]);
    }

    [Fact]
    public void ShaperOffsetsReachTheTextWrittenForALeftToRightLine()
    {
        Assert.Contains(" Ts", Drawn(LayoutAlign.Left, "abc def"));
    }

    [Fact]
    public void ShaperOffsetsReachJustifiedLinesToo()
    {
        string content = Drawn(LayoutAlign.Justify, "abc def abc def abc def abc def abc def abc def abc def abc def");
        Assert.Contains(" Ts", content);
        Assert.Contains("TJ", content);
    }

    internal static IFontSource ScriptFonts() =>
        new OfficeFontSource(null, new ScriptFont(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "shaping", "script.ttf"))));

    private static LayoutDocument Document(params LayoutParagraph[] paragraphs)
    {
        var section = new LayoutSection { Page = new LayoutGeometry { Width = 200, Height = 200, Top = 20, Right = 20, Bottom = 20, Left = 20 } };
        section.Blocks.AddRange(paragraphs);
        return new LayoutDocument { Sections = [section] };
    }

    private static LayoutParagraph Paragraph(string text, bool rtl, LayoutAlign align = LayoutAlign.Left) =>
        new() { Runs = [new LayoutRun { Text = text }], RightToLeft = rtl, Align = align };

    [Fact]
    public void ARightToLeftParagraphStartsAtTheRightEdgeAndItsLinesStaySortedByPlace()
    {
        var layout = new Paginator(Document(Paragraph("אבג דהו זחט יכל מנס עפצ קרש תאב גדה וזח", rtl: true, LayoutAlign.Right)), new LayoutFonts(ScriptFonts()), default).Run();
        var texts = layout.Pages[0].Boxes.OfType<PlacedText>().ToList();
        Assert.True(texts.Count > 1);
        Assert.All(texts, t => Assert.True(t.RightToLeft));
        var face = new LayoutFonts(ScriptFonts()).Find(OfficeFontSource.DefaultFamily, FontStyles.Regular)!;
        foreach (var line in texts.GroupBy(t => t.Baseline))
            Assert.Equal(180, line.Max(t => t.X + t.Text.EnumerateRunes().Sum(r => face.Advance(r.Value)) * t.Size), 0.01);
    }

    [Fact]
    public void RightToLeftTextIsWrittenInDisplayOrderAndReadsBackInLogicalOrder()
    {
        const string text = "אבג abc דהו 12 זחט";
        var made = OfficePdfWriter.Create(Document(Paragraph(text, rtl: true, LayoutAlign.Right)), ScriptFonts());
        using var pdf = PdfDocument.Open(made.Bytes);
        Assert.Equal(text, TextPage.Create(pdf, pdf.Pages[0]).Text.Replace("\n", " "));
        Assert.Empty(made.Missing);
    }

    [Fact]
    public void ALeftToRightParagraphWithoutHebrewLaysOutAsBefore()
    {
        var layout = new Paginator(Document(Paragraph("abc def", rtl: false)), new LayoutFonts(ScriptFonts()), default).Run();
        var text = Assert.Single(layout.Pages[0].Boxes.OfType<PlacedText>());
        Assert.False(text.RightToLeft);
        Assert.Equal(20, text.X);
    }

    [Fact]
    public void RightToLeftLayoutGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, document) in OfficeLayoutSpec.Read(Golden.Input("office-layout", "rtl-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(OfficeLayoutTests.Dump(document, ScriptFonts()));
        }
        Golden.Check("office-layout", "rtl-output.txt", output.ToString());
    }
}
