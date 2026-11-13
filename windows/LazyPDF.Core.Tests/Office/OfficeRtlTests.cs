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
