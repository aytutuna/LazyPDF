using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ExportReviewFixTests
{
    private static readonly XNamespace S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";

    private static ExLine Line(string text, double x, double y, double width = 40, TextBreak before = TextBreak.Line) => new()
    {
        Box = new DisplayRect(x, y, width, 10),
        Runs = [new ExportRun(text, false, false, 10)],
        Size = 10,
        AllBold = false,
        Before = before,
        Block = 0,
    };

    private static ExportDocument OnePage(double width, double height, params ExportBlock[] blocks) =>
        new(null, [new ExportPage(0, width, height, blocks, [], [])], 11);

    private static ExportPicture Picture(double x, double y, double w, double h, int bytes = 8) =>
        new(new DisplayRect(x, y, w, h), new ExportImage(new byte[bytes], true, 8, 6));

    [Fact]
    public void ANonAsciiDigitIsNotAListMarker()
    {
        var rows = ExportFlow.Rows([Line("٣. hello there", 72, 700)]);
        var paragraph = Assert.Single(ExportFlow.Paragraphs(rows));
        Assert.Null(paragraph.Item);
        Assert.False(ExportFlow.IsMarker("٣."));
    }

    [Fact]
    public void TheRtfBulletIsAnEscapeAndTheFileStaysSevenBit()
    {
        var item = new ExportParagraph(new DisplayRect(72, 72, 100, 12), [new ExportRun("Apples", false, false, 11)], 0, new ExportListItem(1, false, 0, 0));
        string rtf = RtfWriter.Make(OnePage(612, 792, item));
        Assert.Contains(@"\fi-360 " + "\\u8226?" + @"\tab ", rtf);
        Assert.All(rtf, c => Assert.True(c < 128));
    }

    [Fact]
    public void AMarkerFindsItsTextAmongManyLines()
    {
        var lines = new List<ExLine?> { Line("text", 80, 100), Line("•", 70, 100, 5), Line("other", 80, 300) };
        ExportFlow.JoinMarkers(lines);
        Assert.Null(lines[1]);
        Assert.Equal("• text", lines[0]!.Text);
        Assert.Equal("other", lines[2]!.Text);
    }

    [Fact]
    public void APageOfBareMarkersIsJoinedInLinearTime()
    {
        var lines = new List<ExLine?>();
        for (int i = 0; i < 30000; i++) lines.Add(Line("•", 10, 12.0 * i, 5));
        var watch = Stopwatch.StartNew();
        ExportFlow.JoinMarkers(lines);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(3), $"took {watch.Elapsed}");
    }

    [Fact]
    public void APictureOnAStampSizedPageHasAPositiveExtent()
    {
        var document = OnePage(30, 40, Picture(2, 2, 26, 36));
        string xml = ExportKit.Unzip(DocxWriter.Make(document), "word/document.xml");
        var extents = Regex.Matches(xml, @"<wp:extent cx=""(-?\d+)"" cy=""(-?\d+)""").ToList();
        Assert.NotEmpty(extents);
        Assert.All(extents, m => Assert.True(long.Parse(m.Groups[1].Value) > 0 && long.Parse(m.Groups[2].Value) > 0));
        var (width, height) = DocxWriter.PaperTwips(document);
        var (top, right, bottom, left) = DocxWriter.MarginsTwips(document, width, height);
        Assert.True(width - left - right > 0 && height - top - bottom > 0);
        string rtf = RtfWriter.Make(document);
        Assert.DoesNotContain("picwgoal-", rtf);
        Assert.DoesNotContain("pichgoal-", rtf);
    }

    [Fact]
    public void PicturesPastTheEmbeddingBudgetAreRefusedNotDropped()
    {
        var big = new ExportImage(new byte[12 << 20], true, 8, 6);
        ExportDocument Many(int count) => OnePage(612, 792, Enumerable.Range(0, count).Select(i => (ExportBlock)new ExportPicture(new DisplayRect(10, 10 + 20 * i, 10, 10), big)).ToArray());
        var over = Many(50);
        Assert.Throws<PdfReadException>(() => HtmlWriter.Reflowed(over));
        Assert.Throws<PdfReadException>(() => MarkdownWriter.Make(over, embedImages: true));
        Assert.Throws<PdfReadException>(() => RtfWriter.Make(over));
        Assert.Empty(Regex.Matches(MarkdownWriter.Make(over), "data:image"));

        var under = Many(3);
        Assert.Equal(3, Regex.Count(HtmlWriter.Reflowed(under), "<img"));
        Assert.Equal(3, Regex.Count(MarkdownWriter.Make(under, embedImages: true), "data:image"));
        Assert.Equal(3, Regex.Count(RtfWriter.Make(under), "jpegblip"));
    }

    [Fact]
    public void TheTextBudgetCountsRunsAndNotOnlyCharacters()
    {
        var content = new System.Text.StringBuilder("BT /F1 4 Tf ");
        for (int i = 0; i < 20000; i++) content.Append($"1 0 0 1 {10 + i % 50 * 11} {780 - i / 50 * 1.5} Tm (x) Tj ");
        content.Append("ET");
        var document = ExportKit.Open(content.ToString());
        Assert.Throws<PdfReadException>(() => ExportLayout.Analyze(document, Enumerable.Repeat(0, 120).ToList()));
        Assert.NotEmpty(ExportLayout.Analyze(document, Enumerable.Repeat(0, 3).ToList()).Pages);
    }

    [Fact]
    public void MarkersAtTheEdgeOfTheirReachAreJoinedInLinearTime()
    {
        var lines = new List<ExLine?>();
        for (int i = 0; i < 100000; i++) lines.Add(Line("text", 80, 100));
        for (int i = 0; i < 100000; i++) lines.Add(Line("•", 70, 105, 5));
        var watch = Stopwatch.StartNew();
        ExportFlow.JoinMarkers(lines);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(3), $"took {watch.Elapsed}");
    }

    [Fact]
    public void ARtfTableStopsAtWordsColumnLimit()
    {
        var row = Enumerable.Range(0, 70).Select(i => "c" + i).ToList();
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), [row], null, true);
        string rtf = RtfWriter.Make(OnePage(612, 792, table));
        Assert.Equal(63, Regex.Count(rtf, @"\\cellx"));
        Assert.Equal(63, Regex.Count(rtf, @"\\cell(?!x)"));
        Assert.Contains("c62 c63 c64", rtf);
        Assert.Contains("c69", rtf);
    }

    [Fact]
    public void ASheetStopsAtTheLastRowExcelAllows()
    {
        var rows = Enumerable.Repeat((IReadOnlyList<string>)["a"], 1048577).ToList();
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), rows, null, true);
        string xml = ExportKit.Unzip(XlsxWriter.Make(OnePage(612, 792, table)), "xl/worksheets/sheet1.xml");
        Assert.Contains("<row r=\"1048576\">", xml);
        Assert.DoesNotContain("r=\"1048577\"", xml);
    }

    [Fact]
    public void ThousandsOfLinesPastTheLastColumnJoinInLinearTime()
    {
        var lines = Enumerable.Range(0, 200000).Select(i => new ExportTextLine(new DisplayRect(10 + 20.0 * i, 10, 1, 10), [new ExportRun("w", false, false, 10)])).ToList();
        var page = new ExportDocument(null, [new ExportPage(0, 612, 792, [], lines, [])], 11);
        var watch = Stopwatch.StartNew();
        var sheet = XDocument.Parse(ExportKit.Unzip(XlsxWriter.Make(page), "xl/worksheets/sheet1.xml"));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), $"took {watch.Elapsed}");
        Assert.Equal(32767, sheet.Descendants(S + "t").Last().Value.Length);
    }

    [Fact]
    public void AZipWithTheZip64CountOfEntriesIsRefused()
    {
        var entries = Enumerable.Range(0, ushort.MaxValue).Select(i => new ExportZipEntry("e" + i, [])).ToList();
        Assert.Throws<PdfReadException>(() => ExportZip.Make(entries));
        entries.RemoveAt(0);
        Assert.NotEmpty(ExportZip.Make(entries));
    }

    [Fact]
    public void APackageOverTheSizeLimitIsRefused()
    {
        var data = new byte[600 << 20];
        Assert.Throws<PdfReadException>(() => ExportZip.Make([new("a", data), new("b", data)]));
    }

    [Fact]
    public void AnOversizedPresentationIsAReadProblem()
    {
        var pages = Enumerable.Range(0, 33000).Select(i => new ExportPage(i, 100, 100, [], [], [])).ToList();
        Assert.Throws<PdfReadException>(() => PptxWriter.Make(new ExportDocument(null, pages, 11)));
    }

    [Fact]
    public void AWideTableStopsAtWordsColumnLimit()
    {
        var row = Enumerable.Range(0, 70).Select(i => "c" + i).ToList();
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), [row, row], null, true);
        string xml = ExportKit.Unzip(DocxWriter.Make(OnePage(612, 792, table)), "word/document.xml");
        Assert.Equal(63, Regex.Count(xml, "<w:gridCol "));
        Assert.Equal(2 * 63, Regex.Count(xml, "<w:tc>"));
        Assert.Contains("c62 c63 c64", xml);
        Assert.Contains("c69", xml);
    }

    [Fact]
    public void ASheetKeepsToExcelsCellColumnAndRowLimits()
    {
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), [new[] { new string('x', 40000), "b" }], null, true);
        var sheet = XDocument.Parse(ExportKit.Unzip(XlsxWriter.Make(OnePage(612, 792, table)), "xl/worksheets/sheet1.xml"));
        Assert.Equal(32767, sheet.Descendants(S + "t").First().Value.Length);

        var lines = Enumerable.Range(0, 16500).Select(i => new ExportTextLine(new DisplayRect(10 + i, 10, 1, 10), [new ExportRun("w" + i, false, false, 10)])).ToList();
        var page = new ExportDocument(null, [new ExportPage(0, 612, 792, [], lines, [])], 11);
        var wide = XDocument.Parse(ExportKit.Unzip(XlsxWriter.Make(page), "xl/worksheets/sheet1.xml"));
        Assert.Equal("A1:XFD1", (string)wide.Descendants(S + "dimension").Single().Attribute("ref")!);
        Assert.All(wide.Descendants(S + "c"), c => Assert.True(((string)c.Attribute("r")!).Length <= 6));
    }
}
