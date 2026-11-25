using System.Text;
using System.Text.RegularExpressions;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

[Collection("ExportLarge")]
public class ExportBoundFixTests
{
    private static ExLine Cell(string text, double x, double y) => new()
    {
        Box = new DisplayRect(x, y, 40, 10),
        Runs = [new ExportRun(text, false, false, 10)],
        Size = 10,
        AllBold = false,
        Before = TextBreak.Tab,
        Block = 0,
    };

    private static ExRow Row(params ExLine[] cells)
    {
        var row = new ExRow();
        row.Cells.AddRange(cells);
        return row;
    }

    private static ExportDocument OnePage(IReadOnlyList<ExportBlock> blocks, IReadOnlyList<ExportTextLine>? lines = null) =>
        new(null, [new ExportPage(0, 612, 792, blocks, lines ?? [], [])], 11);

    private static ExportDocument Paragraphs(int count, int length)
    {
        var paragraph = new ExportParagraph(new DisplayRect(10, 10, 500, 20), [new ExportRun(new string('x', length), false, false, 11)]);
        return OnePage([.. Enumerable.Repeat<ExportBlock>(paragraph, count)]);
    }

    [Fact]
    public void StaggeredCellsDoNotBecomeAMostlyBlankTable()
    {
        var rows = Enumerable.Range(0, 40).Select(i => Row(Cell("a", 100 * (2 * i), 10 * i), Cell("b", 100 * (2 * i + 1), 10 * i))).ToList();
        rows.Add(Row(Cell("p", 0, 400), Cell("q", 100, 400), Cell("r", 200, 400)));
        Assert.Null(ExportFlow.Aligned(rows));
    }

    [Fact]
    public void ColumnsWithSomeBlankCellsStayATable()
    {
        var rows = new List<ExRow>
        {
            Row(Cell("a", 0, 0), Cell("b", 100, 0), Cell("c", 200, 0)),
            Row(Cell("d", 0, 10), Cell("e", 200, 10)),
            Row(Cell("f", 0, 20), Cell("g", 100, 20), Cell("h", 200, 20)),
        };
        var table = ExportFlow.Aligned(rows);
        Assert.Equal(["d", "", "e"], table!.Rows[1]);
    }

    [Fact]
    public void PicturesCountAgainstTheAnalysisBudget()
    {
        var document = ExportKit.Open(string.Concat(Enumerable.Repeat("q 20 0 0 20 100 100 cm /Im1 Do Q ", 400)));
        var ex = Assert.Throws<PdfReadException>(() => ExportLayout.Analyze(document, Enumerable.Repeat(0, 3000).ToList()));
        Assert.Equal(ExportText.TooLarge, ex.Message);
    }

    [Fact]
    public void ALongLedgerOfShortCellsIsStillExported()
    {
        var content = new StringBuilder();
        for (int r = 0; r < 100; r++)
            for (int c = 0; c < 8; c++) content.Append($"BT /F1 5 Tf {20 + 70 * c} {780 - 7 * r} Td (Cell{r % 100:D2}) Tj ET\n");
        var document = ExportKit.Open(content.ToString());
        Assert.Equal(2400, ExportLayout.Analyze(document, Enumerable.Repeat(0, 2400).ToList()).Pages.Count);
    }

    [Fact]
    public void SlidesAreRefusedOnceTheirMarkupPassesTheLimit()
    {
        var picture = new ExportPicture(new DisplayRect(10, 10, 20, 20), new ExportImage(new byte[8], true, 8, 6));
        var page = new ExportPage(0, 612, 792, [], [], [.. Enumerable.Repeat(picture, 400)]);
        var document = new ExportDocument(null, [.. Enumerable.Repeat(page, 700)], 11);
        Assert.Throws<PdfReadException>(() => PptxWriter.Make(document));
    }

    [Fact]
    public void MoreSlidesThanAPackageCanHoldAreRefused()
    {
        var page = new ExportPage(0, 612, 792, [], [], []);
        var document = new ExportDocument(null, [.. Enumerable.Repeat(page, 33000)], 11);
        Assert.Throws<PdfReadException>(() => PptxWriter.Make(document));
    }

    [Fact]
    public void FixedHtmlChecksTheLengthAsLinesAreWritten()
    {
        var line = new ExportTextLine(new DisplayRect(10, 10, 100, 10), [new ExportRun(new string('&', 100), false, false, 11)]);
        var document = OnePage([], [.. Enumerable.Repeat(line, 1_200_000)]);
        Assert.Throws<PdfReadException>(() => HtmlWriter.Fixed(document));
    }

    [Fact]
    public void MarkdownChecksTheLengthOfWhatTheLastBlockAdded()
    {
        Assert.Throws<PdfReadException>(() => MarkdownWriter.Make(Paragraphs(537, 1_000_000)));
    }

    [Fact]
    public void PlainTextChecksTheLengthBeforeTheLastToString()
    {
        Assert.Throws<PdfReadException>(() => PlainTextWriter.Make(Paragraphs(537, 1_000_000)));
    }

    [Fact]
    public void PlainTextBelowTheLimitIsWritten()
    {
        string text = PlainTextWriter.Make(Paragraphs(3, 1000));
        Assert.Equal(3 * 1002 + 1, text.Length);
    }

    [Fact]
    public void DocxBlankCellsOfOneTableCountAgainstTheLimit()
    {
        var blank = Enumerable.Repeat("", 63).ToList();
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), [.. Enumerable.Repeat<IReadOnlyList<string>>(blank, 150_000)], null, true);
        Assert.Throws<PdfReadException>(() => DocxWriter.Make(OnePage([table])));
    }

    [Fact]
    public void AnRtfTableOverTheColumnLimitGivesTheLastCellTheWidthOfTheColumnsItHolds()
    {
        var row = Enumerable.Range(0, 70).Select(i => "c" + i).ToList();
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), [row], Enumerable.Repeat(10.0, 70).ToList(), true);
        var edges = Regex.Matches(RtfWriter.Make(OnePage([table])), @"\\cellx(\d+)").Select(m => long.Parse(m.Groups[1].Value)).ToList();
        Assert.Equal(63, edges.Count);
        long first = edges[0], last = edges[62] - edges[61];
        Assert.InRange(last, 8 * first - 8, 8 * first + 8);
    }

    [Fact]
    public void AnRtfTableWithoutWidthsSharesTheSameWay()
    {
        var row = Enumerable.Range(0, 70).Select(i => "c" + i).ToList();
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), [row], null, false);
        var edges = Regex.Matches(RtfWriter.Make(OnePage([table])), @"\\cellx(\d+)").Select(m => long.Parse(m.Groups[1].Value)).ToList();
        Assert.InRange(edges[62] - edges[61], 8 * edges[0] - 8, 8 * edges[0] + 8);
    }

    [Fact]
    public void ARowShorterThanTheTableReadsAsBlankCells()
    {
        var table = new ExportTable(new DisplayRect(10, 10, 500, 20), [["a", "b"], ["c"]], [10.0], true);
        Assert.NotEmpty(DocxWriter.Make(OnePage([table])));
        Assert.Contains(@"\pard\intbl\fs20 c\cell\pard\intbl\fs20 \cell", RtfWriter.Make(OnePage([table])));
    }

    [Fact]
    public void DigitsOutsideTheBasicPlaneAreNotPageNumbers()
    {
        var row = Row(Cell("\U0001D7CF\U0001D7D0", 10, 780));
        Assert.DoesNotContain(row, ExportStructure.RunningHeads([(792, [row])]));
    }

    [Fact]
    public void HeadsThatDifferOnlyInTheirCompositionAreDifferentHeads()
    {
        var first = Row(Cell("Part \u00E9", 10, 10));
        var second = Row(Cell("Part e\u0301", 10, 10));
        Assert.Empty(ExportStructure.RunningHeads([(792, [first]), (792, [second])]));
    }
}
