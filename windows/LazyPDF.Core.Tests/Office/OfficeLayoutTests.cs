using System.Globalization;
using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class OfficeLayoutTests
{
    private static string Num(double value) => (Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100 + 0.0).ToString("0.00", CultureInfo.InvariantCulture);

    private static string Dump(LayoutDocument document)
    {
        var fonts = OfficeLayoutSpec.Fonts();
        var layout = new Paginator(document, new LayoutFonts(fonts), default).Run();
        var contents = new List<byte[]>();
        OfficePdfWriter.Create(document, fonts, contents: contents);
        var output = new StringBuilder();
        for (int i = 0; i < layout.Pages.Count; i++)
        {
            var page = layout.Pages[i];
            output.Append($"page {i + 1} {Num(page.Width)} {Num(page.Height)}\n");
            foreach (var box in page.Boxes)
            {
                switch (box)
                {
                    case PlacedText t:
                        output.Append($"text {Num(t.X)} {Num(t.Baseline)} {t.Family}/{t.Style} {Num(t.Size)} {t.Color:x6} +{Num(t.SpaceExtra)} \"{OfficeLayoutSpec.Escape(t.Text)}\"\n");
                        break;
                    case PlacedImage img:
                        output.Append($"image {Num(img.X)} {Num(img.Y)} {Num(img.Width)} {Num(img.Height)}\n");
                        break;
                    case PlacedRect r:
                        output.Append($"rect {Num(r.X)} {Num(r.Y)} {Num(r.Width)} {Num(r.Height)} {r.Color:x6}\n");
                        break;
                }
            }
            foreach (string line in Encoding.Latin1.GetString(contents[i]).TrimEnd('\n').Split('\n')) output.Append("| ").Append(line).Append('\n');
        }
        foreach (var s in layout.Skipped) output.Append($"skipped {s.Kind} {s.Count}\n");
        if (layout.Missing.Count > 0) output.Append("missing ").Append(string.Join(' ', layout.Missing.Select(c => c.ToString("x", CultureInfo.InvariantCulture)))).Append('\n');
        return output.ToString();
    }

    [Fact]
    public void LayoutGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, document) in OfficeLayoutSpec.Read(Golden.Input("office-layout", "layout-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(Dump(document));
        }
        Golden.Check("office-layout", "layout-output.txt", output.ToString());
    }

    [Fact]
    public void TablesGoldenFile()
    {
        var output = new StringBuilder();
        foreach (var (name, document) in OfficeLayoutSpec.Read(Golden.Input("office-layout", "tables-input.txt")))
        {
            output.Append("> ").Append(name).Append('\n').Append(Dump(document));
        }
        Golden.Check("office-layout", "tables-output.txt", output.ToString());
    }

    [Fact]
    public void LineBreakGoldenFile()
    {
        var output = new StringBuilder();
        foreach (string line in Golden.Input("office-layout", "linebreak-input.txt").Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string text = OfficeLayoutSpec.Unescape(line);
            var codes = text.EnumerateRunes().Select(r => r.Value).ToList();
            var breaks = LineBreaker.Opportunities(codes);
            var chunk = new StringBuilder();
            output.Append("> ").Append(line).Append('\n').Append("< ");
            for (int i = 0; i < codes.Count; i++)
            {
                if (breaks[i]) output.Append(OfficeLayoutSpec.Escape(chunk.ToString())).Append('|');
                if (breaks[i]) chunk.Clear();
                chunk.Append(char.ConvertFromUtf32(codes[i]));
            }
            output.Append(OfficeLayoutSpec.Escape(chunk.ToString())).Append('\n');
        }
        Golden.Check("office-layout", "linebreak-output.txt", output.ToString());
    }

    [Fact]
    public void TheTabAfterAListNumberRunsToItsStopOrTheHangingIndent()
    {
        var page = new LayoutGeometry { Width = 300, Height = 200, Top = 10, Right = 10, Bottom = 10, Left = 10 };
        double TextX(double left, double first, double? stop)
        {
            var paragraph = new LayoutParagraph { Runs = [new LayoutRun { Text = "1." + (char)9 + "word" }], Left = left, FirstLine = first, LabelTab = stop };
            return Texts(Layout(Single(page, paragraph)).Pages[0]).Single(t => t.Text.Contains("word")).X;
        }
        Assert.Equal(10 + 50, TextX(0, 0, 50), 2);
        Assert.Equal(10 + 40, TextX(40, -40, null), 2);
        Assert.Equal(10 + 30, TextX(40, -40, 30), 2);
        Assert.Equal(10 + 36, TextX(0, 0, null), 2);
    }

    private static LayoutDocument Single(LayoutGeometry page, params LayoutBlock[] blocks) =>
        new() { Sections = [new LayoutSection { Page = page, Blocks = [.. blocks] }] };

    private static LayoutParagraph Paragraph(string text, LayoutAlign align = LayoutAlign.Left, bool keep = false, bool widow = true, double size = 11, double after = 0) =>
        new() { Runs = [new LayoutRun { Text = text, Size = size }], Align = align, KeepWithNext = keep, WidowControl = widow, After = after };

    private static readonly LayoutGeometry Small = new() { Width = 100, Height = 100, Top = 10, Right = 10, Bottom = 10, Left = 10 };

    private static LayoutResult Layout(LayoutDocument document) => new Paginator(document, new LayoutFonts(OfficeLayoutSpec.Fonts()), default).Run();

    private static IEnumerable<PlacedText> Texts(LayoutPage page) => page.Boxes.OfType<PlacedText>();

    private const string Words = "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega";

    [Fact]
    public void LinesStayInsideTheTextArea()
    {
        var layout = Layout(Single(new LayoutGeometry { Width = 200, Height = 200, Top = 20, Right = 20, Bottom = 20, Left = 20 }, Paragraph(Words + " " + Words)));
        var fonts = new LayoutFonts(OfficeLayoutSpec.Fonts());
        Assert.All(Texts(layout.Pages[0]), t => Assert.InRange(t.X, 20, 180));
        var face = fonts.Find("Carlito", FontStyles.Regular)!;
        Assert.All(Texts(layout.Pages[0]), t => Assert.True(t.X + t.Text.TrimEnd().Sum(c => face.Advance(c)) * t.Size <= 180.01, t.Text));
    }

    [Fact]
    public void JustifiedLinesReachBothEdgesExceptTheLast()
    {
        var geometry = new LayoutGeometry { Width = 200, Height = 200, Top = 20, Right = 20, Bottom = 20, Left = 20 };
        var layout = Layout(Single(geometry, Paragraph(Words, align: LayoutAlign.Justify)));
        var face = new LayoutFonts(OfficeLayoutSpec.Fonts()).Find("Carlito", FontStyles.Regular)!;
        var lines = Texts(layout.Pages[0]).ToList();
        Assert.True(lines.Count > 2);
        foreach (var t in lines.Take(lines.Count - 1))
        {
            string ink = t.Text.TrimEnd();
            double ends = t.X + ink.Sum(c => face.Advance(c)) * t.Size + ink.Count(c => c == ' ') * t.SpaceExtra;
            Assert.Equal(180, ends, 3);
        }
        Assert.Equal(0, lines[^1].SpaceExtra);
    }

    [Fact]
    public void WidowControlLeavesAtLeastTwoLinesOnEitherSide()
    {
        // Five lines fit a page of this size; a nine line paragraph would leave one on the second page.
        var layout = Layout(Single(Small, Paragraph(string.Join(" ", Enumerable.Repeat("word", 40)))));
        var counts = layout.Pages.Select(p => Texts(p).Count()).ToList();
        Assert.True(counts.Count > 1);
        Assert.All(counts, c => Assert.True(c >= 2));
        var loose = Layout(Single(Small, Paragraph(string.Join(" ", Enumerable.Repeat("word", 40)), widow: false)));
        Assert.Equal(loose.Pages.Sum(p => Texts(p).Count()), counts.Sum());
    }

    [Fact]
    public void KeepWithNextMovesTheHeadingToThePageOfItsParagraph()
    {
        var filler = Paragraph(string.Join(" ", Enumerable.Repeat("word", 26)));
        var next = Paragraph("one two three four five six");
        var layout = Layout(Single(Small, filler, Paragraph("Heading", keep: true), next));
        Assert.Equal(3, layout.Pages.Count);
        Assert.Equal("Heading", Texts(layout.Pages[2]).First().Text);
        var loose = Layout(Single(Small, filler, Paragraph("Heading"), next));
        Assert.Contains(Texts(loose.Pages[1]), t => t.Text == "Heading");
    }

    [Fact]
    public void PageBreakStartsAPage()
    {
        var layout = Layout(Single(Small, Paragraph("One"), new LayoutPageBreak(), Paragraph("Two")));
        Assert.Equal(2, layout.Pages.Count);
        Assert.Equal(["One"], Texts(layout.Pages[0]).Select(t => t.Text));
        Assert.Equal(["Two"], Texts(layout.Pages[1]).Select(t => t.Text));
    }

    [Fact]
    public void SpaceBeforeIsKeptAfterAHardBreakAndDroppedAfterASoftOne()
    {
        var spaced = new LayoutParagraph { Runs = [new LayoutRun { Text = "Next" }], Before = 20 };
        var hard = Layout(Single(Small, Paragraph("A"), new LayoutPageBreak(), spaced));
        var plain = Layout(Single(Small, Paragraph("A"), new LayoutPageBreak(), Paragraph("Next")));
        Assert.Equal(Texts(plain.Pages[1]).Single().Baseline + 20, Texts(hard.Pages[1]).Single().Baseline, 6);

        var filler = Paragraph(string.Join(" ", Enumerable.Repeat("word", 44)));
        var soft = Layout(Single(Small, filler, spaced));
        var start = Texts(soft.Pages[^1]).First();
        Assert.Equal("Next", start.Text);
        Assert.Equal(Texts(plain.Pages[0]).First().Baseline, start.Baseline, 6);
    }

    [Fact]
    public void HeaderAndFooterCarryThePageNumberAndTheCount()
    {
        var footer = new LayoutParagraph { Runs = [new LayoutRun { Text = "Page " }, new LayoutRun { Field = LayoutField.PageNumber }, new LayoutRun { Text = " of " }, new LayoutRun { Field = LayoutField.PageCount }] };
        var document = Single(Small, Paragraph("One"), new LayoutPageBreak(), Paragraph("Two"), new LayoutPageBreak(), Paragraph("Three"));
        document.Sections[0].Footer.Add(footer);
        var made = OfficePdfWriter.Create(document, OfficeLayoutSpec.Fonts());
        Assert.Equal(3, made.Pages);
        using var pdf = PdfDocument.Open(made.Bytes);
        for (int i = 0; i < 3; i++) Assert.Contains($"Page {i + 1} of 3", TextPage.Create(pdf, pdf.Pages[i]).Text);
    }

    [Fact]
    public void TextStaysSelectableAndTheFileReopens()
    {
        var document = Single(new LayoutGeometry { Width = 200, Height = 200, Top = 20, Right = 20, Bottom = 20, Left = 20 },
            Paragraph("Dünya ğ ş ı İ çok güzel, shall we meet at noon", align: LayoutAlign.Justify));
        var made = OfficePdfWriter.Create(document, OfficeLayoutSpec.Fonts());
        using var pdf = PdfDocument.Open(made.Bytes);
        Assert.Equal("Dünya ğ ş ı İ çok güzel, shall we meet at noon", TextPage.Create(pdf, pdf.Pages[0]).Text.Replace("\n", " "));
        Assert.Empty(made.Missing);

        var plain = OfficePdfWriter.Create(Single(Small, Paragraph("shall we meet at noon")), OfficeLayoutSpec.Fonts());
        using var pig = PigDocument.Open(plain.Bytes);
        Assert.Equal(1, pig.NumberOfPages);
        // PdfPig guesses word gaps from glyph positions and loses some, so only the letters are compared.
        Assert.Equal("shallwemeetatnoon", string.Concat(pig.GetPage(1).Text.Where(char.IsLetter)));
    }

    [Fact]
    public void ScriptsThatNeedShapingAreReportedAndGlyphGapsAreListed()
    {
        var document = Single(Small, Paragraph("abc שלום"), Paragraph("السلام"), Paragraph("नमस्ते"), Paragraph("中"));
        document.Skipped.Add(new SkippedFeature("charts", 1));
        var made = OfficePdfWriter.Create(document, OfficeLayoutSpec.Fonts());
        Assert.Equal([new SkippedFeature("charts", 1), new SkippedFeature(SkippedKinds.RightToLeftText, 2), new SkippedFeature(SkippedKinds.ComplexScript, 1)], made.Skipped);
        Assert.Contains(0x4E2D, made.Missing);
    }

    [Fact]
    public void ABandThatLeavesNoBodyGivesWayToTheMargins()
    {
        var document = Single(Small, Paragraph("Body"));
        document.Sections[0].Header.Add(Paragraph("Header", size: 90));
        Assert.Equal(["Body"], Texts(Layout(document).Pages[0]).Where(t => t.Size == 11).Select(t => t.Text));
    }

    [Fact]
    public void ExactSpacingSetsTheLineHeight()
    {
        var paragraph = new LayoutParagraph { Runs = [new LayoutRun { Text = string.Join(" ", Enumerable.Repeat("word", 12)) }], Rule = LineRule.Exact, LineSpacing = 20 };
        var baselines = Texts(Layout(Single(new LayoutGeometry { Width = 100, Height = 400, Top = 10, Right = 10, Bottom = 10, Left = 10 }, paragraph)).Pages[0]).Select(t => t.Baseline).ToList();
        Assert.True(baselines.Count > 2);
        Assert.All(baselines.Zip(baselines.Skip(1)), p => Assert.Equal(20, p.Second - p.First, 6));
    }

    [Fact]
    public void BadGeometryAndRunawayLengthAreRefused()
    {
        var narrow = Single(new LayoutGeometry { Width = 100, Height = 100, Left = 50, Right = 40 }, Paragraph("x"));
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => OfficePdfWriter.Create(narrow, OfficeLayoutSpec.Fonts())).Problem);
        var huge = Single(new LayoutGeometry { Width = 100000, Height = 100 }, Paragraph("x"));
        Assert.Throws<PdfReadException>(() => OfficePdfWriter.Create(huge, OfficeLayoutSpec.Fonts()));

        var breaks = Enumerable.Repeat<LayoutBlock>(new LayoutPageBreak(), Paginator.MaxPages + 1).ToArray();
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => OfficePdfWriter.Create(Single(Small, breaks), OfficeLayoutSpec.Fonts())).Problem);
    }

    [Fact]
    public void AnUnbrokenStringLongerThanTheLineIsCutAtTheEdge()
    {
        var layout = Layout(Single(Small, Paragraph(new string('W', 60))));
        var lines = Texts(layout.Pages[0]).ToList();
        Assert.True(lines.Count > 3);
        Assert.Equal(60, lines.Sum(l => l.Text.Length) + layout.Pages.Skip(1).Sum(p => Texts(p).Sum(l => l.Text.Length)));
    }

    [Fact]
    public void WithoutAnyFontTheDocumentIsRefused()
    {
        var error = Assert.Throws<InvalidOperationException>(() => OfficePdfWriter.Create(Single(Small, Paragraph("x")), null));
        Assert.Equal(ExportText.NoFont, error.Message);
    }

    [Fact]
    public void CancellationStopsTheLayout()
    {
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() => OfficePdfWriter.Create(Single(Small, Paragraph("x")), OfficeLayoutSpec.Fonts(), source.Token));
    }
}
