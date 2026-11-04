using System.Text;
using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextLayoutTests
{
    private static string Column(double x, double top, string prefix, int lines, double pitch = 12)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < lines; i++) sb.Append(Line(x, top - i * pitch, $"{prefix} line {i + 1} of the column"));
        return sb.ToString();
    }

    [Fact]
    public void LinesOfAParagraphJoinWithLineFeeds()
    {
        var page = Text(Line(50, 700, "first line here") + Line(50, 688, "second line here"));
        Assert.Equal("first line here\nsecond line here", page.Text);
        Assert.Single(page.Blocks);
        Assert.Equal(2, page.Lines.Count);
    }

    [Fact]
    public void SmallLineUnderAHeadingIsNotTakenForAScript()
    {
        var page = Text(Line(50, 700, "Questions", 44) + Line(50, 678, "Expenses and more", 20));
        Assert.Equal(2, page.Lines.Count);
        Assert.Contains("Expenses and more", page.Text);
        Assert.StartsWith("Questions", page.Text);
    }

    [Fact]
    public void ABigGapStartsANewBlock()
    {
        var page = Text(Line(50, 700, "one") + Line(50, 688, "two") + Line(50, 650, "three"));
        Assert.Equal("one\ntwo\n\nthree", page.Text);
        Assert.Equal(2, page.Blocks.Count);
    }

    [Fact]
    public void TwoColumnsAreReadOneAfterTheOther()
    {
        var page = Text(Column(50, 700, "left", 6) + Column(330, 700, "right", 6));
        var text = page.Text;
        Assert.True(text.IndexOf("left line 6", StringComparison.Ordinal) < text.IndexOf("right line 1", StringComparison.Ordinal));
        Assert.Equal(12, page.Lines.Count);
        Assert.StartsWith("left line 1 of the column\nleft line 2", text);
    }

    [Fact]
    public void ANumberInTheGutterDoesNotJoinTheColumns()
    {
        string content = Column(50, 700, "left", 8) + Column(330, 700, "right", 8) + Line(295, 40, "7");
        var text = Text(content).Text;
        Assert.True(text.IndexOf("left line 8", StringComparison.Ordinal) < text.IndexOf("right line 1", StringComparison.Ordinal));
        Assert.EndsWith("7", text);
    }

    [Fact]
    public void AHeadingAcrossBothColumnsComesFirstAndAFootnoteLast()
    {
        string content = Line(150, 760, "A heading across the whole page") + Column(50, 720, "left", 5) + Column(330, 720, "right", 5)
            + Line(50, 100, "a note under both columns is long enough to cross the gutter between them");
        var text = Text(content).Text;
        int heading = text.IndexOf("heading", StringComparison.Ordinal), left = text.IndexOf("left line 1", StringComparison.Ordinal);
        int right = text.IndexOf("right line 1", StringComparison.Ordinal), note = text.IndexOf("a note", StringComparison.Ordinal);
        Assert.True(heading < left && left < right && right < note);
    }

    [Fact]
    public void ColumnsWhoseParagraphGapsLineUpAreStillReadDownwards()
    {
        string content = Column(50, 700, "left a", 3) + Column(50, 640, "left b", 3) + Column(330, 700, "right a", 3) + Column(330, 640, "right b", 3);
        var text = Text(content).Text;
        Assert.True(text.IndexOf("left b line 3", StringComparison.Ordinal) < text.IndexOf("right a line 1", StringComparison.Ordinal));
    }

    [Fact]
    public void ATableKeepsItsRowsWithTabsBetweenCells()
    {
        var sb = new StringBuilder();
        for (int row = 0; row < 4; row++)
        {
            double y = 600 - row * 16;
            sb.Append(Line(50, y, $"name{row}")).Append(Line(200, y, $"{row * 11}")).Append(Line(350, y, $"city{row}"));
        }
        var page = Text(sb.ToString());
        Assert.Equal("name0\t0\tcity0\nname1\t11\tcity1\nname2\t22\tcity2\nname3\t33\tcity3", page.Text);
        Assert.True(page.Blocks[0].IsTable);
    }

    [Fact]
    public void ATwoRowTableOfThreeColumnsIsATable()
    {
        string content = Line(50, 600, "a") + Line(200, 600, "b") + Line(350, 600, "c") + Line(50, 584, "d") + Line(200, 584, "e") + Line(350, 584, "f");
        Assert.Equal("a\tb\tc\nd\te\tf", Text(content).Text);
    }

    [Fact]
    public void ASuperscriptStaysOnItsLine()
    {
        var page = Text("BT /F1 10 Tf 100 700 Td (E = mc) Tj /F1 6 Tf 4 Ts (2) Tj ET");
        Assert.Single(page.Lines);
        Assert.Equal("E = mc2", page.Text);
    }

    [Fact]
    public void TextInDifferentSizesOnOneBaselineIsOneLine()
    {
        var page = Text("BT /F1 20 Tf 100 700 Td (Big) Tj 8 Tf ( small) Tj ET");
        Assert.Single(page.Lines);
        Assert.Equal("Big small", page.Text);
    }

    [Fact]
    public void ReadingOrderFollowsPositionNotTheContentStream()
    {
        var page = Text(Line(50, 650, "third") + Line(50, 700, "first") + Line(50, 676, "second"));
        Assert.Equal(["first", "second", "third"], page.Lines.Select(l => l.Text));
    }

    [Fact]
    public void ARotatedPageIsReadAsItIsShown()
    {
        string lines = string.Concat(new[] { (100, "first"), (112, "second"), (124, "third") }
            .Select(l => $"BT /F1 10 Tf 0 1 -1 0 {l.Item1} 100 Tm ({l.Item2} line of text) Tj ET\n"));
        var page = Text(lines, "/Rotate 90");
        Assert.Equal(["first line of text", "second line of text", "third line of text"], page.Lines.Select(l => l.Text));
        Assert.Equal("first line of text\nsecond line of text\nthird line of text", page.Text);
    }

    [Fact]
    public void ATurnedPageGivesTheSameWordsAsTheUpright()
    {
        var upright = Text(Line(50, 700, "alpha beta") + Line(50, 688, "gamma delta"));
        var turned = Text("BT /F1 10 Tf 0 -1 1 0 62 700 Tm (alpha beta) Tj ET BT /F1 10 Tf 0 -1 1 0 50 700 Tm (gamma delta) Tj ET", "/Rotate 270");
        Assert.Equal(upright.Words.Select(w => w.Text), turned.Words.Select(w => w.Text));
    }

    [Fact]
    public void VerticalWritingRunsDownColumnsFromRightToLeft()
    {
        string cid = "<</Type /Font /Subtype /CIDFontType2 /BaseFont /X /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /DW 1000>>";
        string type0 = "<</Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-V /DescendantFonts [7 0 R] /ToUnicode 8 0 R>>";
        string cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange " +
                      "6 beginbfchar <0001> <0041> <0002> <0042> <0003> <0043> <0004> <0044> <0005> <0045> <0006> <0046> endbfchar endcmap";
        var document = Page("BT /V 10 Tf 300 700 Td <000100020003> Tj ET BT /V 10 Tf 280 700 Td <000400050006> Tj ET", "/Font <</V 6 0 R>>", "", pdf =>
        {
            pdf.Obj(6, type0);
            pdf.Obj(7, cid);
            pdf.Stream(8, "", cmap);
        });
        var page = TextPage.Create(document, document.Pages[0]);
        Assert.Equal("ABC\nDEF", page.Text);
        Assert.All(page.Lines, l => Assert.True(l.IsVertical));
    }

    [Fact]
    public void RotatedLabelsComeAfterTheMainText()
    {
        string content = "BT /F1 10 Tf 0 1 -1 0 30 300 Tm (side label) Tj ET " + Line(100, 700, "main text") + Line(100, 688, "more main text");
        var page = Text(content);
        Assert.Equal("main text\nmore main text\n\nside label", page.Text);
    }

    [Fact]
    public void LargePagesStayFast()
    {
        var sb = new StringBuilder();
        for (int i = 0; i < 80; i++) sb.Append(Line(50, 780 - i * 9, string.Concat(Enumerable.Repeat("word ", 16)), 8));
        var document = Page(sb.ToString());
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var page = TextPage.Create(document, document.Pages[0]);
        Assert.True(watch.ElapsedMilliseconds < 1500, $"{watch.ElapsedMilliseconds} ms");
        Assert.Equal(80, page.Lines.Count);
    }
}
