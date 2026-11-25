using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;
using Xunit;

using PigDocument = UglyToad.PdfPig.PdfDocument;

namespace LazyPDF.Core.Tests;

public class OfficeTableTests
{
    private static byte[] Docx(string body) => DocxSpec.Package(new Dictionary<string, StringBuilder> { ["document"] = new(body) });

    private static string Cell(string text, string properties = "") =>
        $"<w:tc>{(properties.Length == 0 ? "" : $"<w:tcPr>{properties}</w:tcPr>")}<w:p><w:r><w:t>{text}</w:t></w:r></w:p></w:tc>";

    private static string Row(string cells, string properties = "") =>
        $"<w:tr>{(properties.Length == 0 ? "" : $"<w:trPr>{properties}</w:trPr>")}{cells}</w:tr>";

    private static string Table(string rows, params int[] grid) =>
        $"<w:tbl><w:tblGrid>{string.Concat(grid.Select(w => $"<w:gridCol w:w=\"{w}\"/>"))}</w:tblGrid>{rows}</w:tbl>";

    private static LayoutResult Layout(LayoutDocument document) => new Paginator(document, new LayoutFonts(OfficeLayoutSpec.Fonts()), default).Run();

    private static LayoutTable ReadTable(string body) => (LayoutTable)DocxReader.Read(Docx(body)).Sections[0].Blocks.Single();

    private static LayoutDocument Single(LayoutGeometry page, params LayoutBlock[] blocks) =>
        new() { Sections = [new LayoutSection { Page = page, Blocks = [.. blocks] }] };

    private static readonly LayoutGeometry Small = new() { Width = 200, Height = 200, Top = 20, Right = 20, Bottom = 20, Left = 20 };

    private static LayoutParagraph Paragraph(string text) => new() { Runs = [new LayoutRun { Text = text }] };

    private static LayoutCell Lc(params string[] paragraphs) => new() { Paragraphs = [.. paragraphs.Select(Paragraph)] };

    private static IEnumerable<PlacedText> Texts(LayoutPage page) => page.Boxes.OfType<PlacedText>();

    [Fact]
    public void ConvertsATableToAPdfWithItsCellsInReadingOrder()
    {
        string body = Table(Row(Cell("a1") + Cell("b1")) + Row(Cell("a2") + Cell("b2")), 3000, 3000);
        var pdf = OfficeConverter.FromWord(Docx(body), OfficeLayoutSpec.Fonts());
        Assert.DoesNotContain(pdf.Skipped, s => s.Kind == "table");
        using var read = PigDocument.Open(pdf.Bytes);
        Assert.Equal("a1 b1a2 b2".Replace(" ", ""), read.GetPage(1).Text.Replace(" ", "").Replace("\n", ""));
    }

    [Fact]
    public void ColumnsStartWhereTheGridPutsThem()
    {
        var document = DocxReader.Read(Docx(Table(Row(Cell("a") + Cell("b") + Cell("c")), 2000, 3000, 1000)));
        var texts = Texts(Layout(document).Pages[0]).ToList();
        Assert.Equal([72 + 5.4, 72 + 100 + 5.4, 72 + 250 + 5.4], texts.Select(t => Math.Round(t.X, 2)).ToArray());
    }

    [Fact]
    public void ASpanTakesTheWidthOfItsColumnsAndAMergeTheHeightOfItsRows()
    {
        string body = Table(
            Row(Cell("wide", "<w:gridSpan w:val=\"2\"/>") + Cell("tall", "<w:vMerge w:val=\"restart\"/>")) +
            Row(Cell("x") + Cell("y") + "<w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc>"), 1000, 1000, 1000);
        var table = ReadTable(body);
        Assert.Equal([2, 1], table.Rows[0].Cells.Select(c => c.Span));
        Assert.Equal(2, table.Rows[0].Cells[1].RowSpan);
        Assert.Equal(2, table.Rows[1].Cells.Count);
    }

    [Fact]
    public void ACellFacingTwoBordersTakesTheWiderOne()
    {
        string wide = "<w:tcBorders><w:right w:val=\"single\" w:sz=\"16\" w:color=\"FF0000\"/></w:tcBorders>";
        string thin = "<w:tcBorders><w:left w:val=\"single\" w:sz=\"4\" w:color=\"000000\"/></w:tcBorders>";
        var table = ReadTable(Table(Row(Cell("a", wide) + Cell("b", thin)), 2000, 2000));
        Assert.Equal(new LayoutBorder(2, 0xFF0000), table.Rows[0].Cells[0].Right);
        Assert.Equal(new LayoutBorder(2, 0xFF0000), table.Rows[0].Cells[1].Left);
    }

    [Fact]
    public void ATableWithoutBordersDrawsNoLines()
    {
        var document = DocxReader.Read(Docx(Table(Row(Cell("a") + Cell("b")), 2000, 2000)));
        Assert.Empty(Layout(document).Pages[0].Boxes.OfType<PlacedRect>());
    }

    [Fact]
    public void HeaderRowsComeBackOnEveryPageTheTableContinuesOn()
    {
        var rows = new StringBuilder(Row(Cell("HEADING"), "<w:tblHeader/>"));
        for (int i = 0; i < 120; i++) rows.Append(Row(Cell("row" + i)));
        var pdf = OfficeConverter.FromWord(Docx(Table(rows.ToString(), 4000)), OfficeLayoutSpec.Fonts());
        Assert.True(pdf.Pages > 2);
        using var read = PigDocument.Open(pdf.Bytes);
        for (int p = 1; p <= pdf.Pages; p++)
        {
            string text = read.GetPage(p).Text;
            Assert.Equal(0, text.IndexOf("HEADING", StringComparison.Ordinal));
            if (p > 1) Assert.DoesNotContain("row0", text);
        }
        Assert.Contains("row119", read.GetPage(pdf.Pages).Text);
    }

    [Fact]
    public void AHeaderTooTallToShareThePageIsNotRepeated()
    {
        var header = new LayoutRow { Header = true, Cells = [Lc(Enumerable.Repeat("HEAD", 8).ToArray())] };
        var rows = Enumerable.Range(0, 30).Select(i => new LayoutRow { Cells = [Lc("row" + i)] });
        var table = new LayoutTable { Columns = [100], Rows = [header, .. rows] };
        var layout = Layout(Single(Small, table));
        Assert.True(layout.Pages.Count > 1);
        Assert.Equal(8, layout.Pages.SelectMany(Texts).Count(t => t.Text == "HEAD"));
    }

    [Fact]
    public void ARowCutBetweenLinesLosesNothing()
    {
        string words = string.Join(" ", Enumerable.Range(0, 150).Select(i => "w" + i));
        var table = new LayoutTable { Columns = [100, 60], Rows = [new LayoutRow { Cells = [Lc(words), new LayoutCell { Column = 1, Paragraphs = [Paragraph("beside")] }] }] };
        var layout = Layout(Single(Small, table));
        Assert.True(layout.Pages.Count > 2);
        var shown = string.Join(" ", layout.Pages.SelectMany(Texts).Where(t => t.X < 100).Select(t => t.Text.Trim())).Split(' ');
        Assert.Equal(Enumerable.Range(0, 150).Select(i => "w" + i), shown);
        Assert.Equal(1, layout.Pages.SelectMany(Texts).Count(t => t.Text == "beside"));
    }

    [Fact]
    public void ARowThatCannotSplitMovesToTheNextPageWhole()
    {
        var filler = Paragraph(string.Join(" ", Enumerable.Repeat("filler", 60)));
        var row = new LayoutRow { CantSplit = true, Cells = [Lc("one", "two", "three")] };
        var layout = Layout(Single(Small, filler, new LayoutTable { Columns = [100], Rows = [row] }));
        Assert.Equal(2, layout.Pages.Count);
        Assert.Equal(["one", "two", "three"], Texts(layout.Pages[1]).Select(t => t.Text));
    }

    [Fact]
    public void AMergeTallerThanAPageBreaksLikeAnyOtherRow()
    {
        var tall = new LayoutCell { RowSpan = 2, Paragraphs = [.. Enumerable.Range(0, 40).Select(i => Paragraph("line" + i))] };
        var table = new LayoutTable
        {
            Columns = [100, 60],
            Rows = [new LayoutRow { Cells = [tall, Lc("a")] }, new LayoutRow { Cells = [new LayoutCell { Column = 1, Paragraphs = [Paragraph("b")] }] }],
        };
        var layout = Layout(Single(Small, table));
        var all = layout.Pages.SelectMany(Texts).Select(t => t.Text).ToList();
        Assert.Equal(40, all.Count(t => t.StartsWith("line", StringComparison.Ordinal)));
        Assert.Contains("a", all);
        Assert.Contains("b", all);
    }

    [Fact]
    public void ACellTallerThanThePageAndAWordWiderThanItsCellStillEnd()
    {
        var wide = new LayoutCell { Paragraphs = [Paragraph(new string('W', 400))] };
        var rows = Enumerable.Range(0, 3).Select(_ => new LayoutRow { CantSplit = true, Cells = [wide] });
        var layout = Layout(Single(Small, new LayoutTable { Columns = [60], Rows = [.. rows] }));
        Assert.InRange(layout.Pages.Count, 1, 40);
    }

    [Fact]
    public void EmptyTablesAndRowsAreHarmless()
    {
        Assert.Single(Layout(Single(Small, new LayoutTable { Columns = [], Rows = [] })).Pages);
        var rows = new LayoutTable { Columns = [0, 0], Rows = [new LayoutRow(), new LayoutRow { Cells = [new LayoutCell()] }] };
        Assert.Single(Layout(Single(Small, rows)).Pages);
    }

    [Fact]
    public void ATableTooWideForThePageIsNarrowedToIt()
    {
        var table = new LayoutTable { Columns = [300, 300], Rows = [new LayoutRow { Cells = [Lc("a"), new LayoutCell { Column = 1, Paragraphs = [Paragraph("b")] }] }] };
        var texts = Texts(Layout(Single(Small, table)).Pages[0]).ToList();
        Assert.Equal(20 + 80 + 5.4, texts[1].X, 2);
    }

    [Fact]
    public void ALimitedTableIsReadAsItsParagraphsAndCounted()
    {
        string columns = Table(Row(string.Concat(Enumerable.Range(0, 64).Select(i => Cell("c" + i)))));
        var document = DocxReader.Read(Docx(columns));
        Assert.Equal(64, document.Sections[0].Blocks.OfType<LayoutParagraph>().Count());
        Assert.Contains(document.Skipped, s => s is { Kind: "table", Count: 1 });

        string rows = Table(string.Concat(Enumerable.Repeat(Row(Cell("r")), 5001)), 1000);
        document = DocxReader.Read(Docx(rows));
        Assert.Equal(5001, document.Sections[0].Blocks.OfType<LayoutParagraph>().Count());
    }

    [Fact]
    public void ASpanIsHeldToTheMostColumnsATableHas()
    {
        var table = ReadTable(Table(Row(Cell("a", "<w:gridSpan w:val=\"900\"/>")), 1000, 1000));
        Assert.Equal(63, table.Rows[0].Cells[0].Span);
        Assert.Equal(63, table.Columns.Count);
        Assert.Equal(2, ReadTable(Table(Row(Cell("a", "<w:gridSpan w:val=\"-4\"/>") + Cell("b")), 1000, 1000)).Rows[0].Cells.Count);
    }

    [Fact]
    public void NestedTablesInManyLevelsEndWithAnErrorOrAResult()
    {
        string inner = "<w:p><w:r><w:t>deep</w:t></w:r></w:p>";
        for (int i = 0; i < 60; i++) inner = $"<w:tbl><w:tr><w:tc>{inner}<w:p/></w:tc></w:tr></w:tbl>";
        try
        {
            var document = DocxReader.Read(Docx(inner));
            Assert.Contains(document.Skipped, s => s.Kind == "table");
        }
        catch (PdfReadException)
        {
        }
    }

    [Fact]
    public void ALongTableIsLaidOutWithinASecond()
    {
        var rows = new StringBuilder();
        for (int i = 0; i < 4000; i++) rows.Append(Row(Cell("a" + i) + Cell("b" + i) + Cell("c" + i)));
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var pdf = OfficeConverter.FromWord(Docx(Table(rows.ToString(), 2000, 2000, 2000)), OfficeLayoutSpec.Fonts());
        Assert.True(pdf.Pages > 20);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(30), watch.Elapsed.ToString());
    }
}
