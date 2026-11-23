using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The page list and options the print flow builds before the system dialog's paper takes the pages.
public sealed class PrintLayoutTests
{
    [Fact]
    public void ThePlainLayoutChangesNothing()
    {
        var layout = new PrintLayout();

        Assert.True(layout.IsPlain);
        Assert.False(layout.Imposes);
        Assert.Equal([0, 1, 2, 3], layout.Pages(null, 4));
    }

    [Fact]
    public void OddAndEvenAreByPageNumber()
    {
        Assert.Equal([0, 2, 4], new PrintLayout(Parity: PrintParity.Odd).Pages(null, 5));
        Assert.Equal([1, 3], new PrintLayout(Parity: PrintParity.Even).Pages(null, 4));
    }

    [Fact]
    public void TheChosenRangeIsCutDownToTheOddOrEvenPagesInIt()
    {
        Assert.Equal([3, 5], new PrintLayout(Parity: PrintParity.Even).Pages([2, 3, 4, 5], 8));
        Assert.Empty(new PrintLayout(Parity: PrintParity.Even).Pages([2], 8));
    }

    [Fact]
    public void OddOrEvenAloneDoesNotImpose()
    {
        var layout = new PrintLayout(Parity: PrintParity.Odd);

        Assert.False(layout.IsPlain);
        Assert.False(layout.Imposes);
    }

    [Theory]
    [InlineData(2)]
    [InlineData(16)]
    public void SeveralPagesPerSheetImpose(int per)
    {
        var options = new PrintLayout(PerSheet: per).Options(612, 792);

        Assert.True(new PrintLayout(PerSheet: per).Imposes);
        Assert.Equal(ImposeMode.NUp, options.Mode);
        Assert.Equal(per, options.PerSheet);
        Assert.Equal((612, 792), (options.SheetWidth, options.SheetHeight));
    }

    [Fact]
    public void ABookletWinsOverPagesPerSheet()
    {
        var layout = new PrintLayout(PerSheet: 4, Booklet: true);

        Assert.True(layout.Imposes);
        Assert.Equal(ImposeMode.Booklet, layout.Options(612, 792).Mode);
    }

    [Fact]
    public void TheSheetsAreASavedFileOfTheRightCount()
    {
        var source = PdfDocument.Open(Pdfs.Text(5));
        var before = source.SaveRewrite();

        var sheets = new PrintLayout(PerSheet: 2).Sheets(source, [0, 1, 2, 3, 4], 612, 792);

        Assert.Equal(3, sheets.Count);
        Assert.Equal(3, PdfDocument.Open(sheets.Bytes).Pages.Count);
        // The second half of the /ID is random.
        string WithoutId(byte[] file) => System.Text.RegularExpressions.Regex.Replace(System.Text.Encoding.Latin1.GetString(file), @"/ID\s*\[[^\]]*\]", "");
        Assert.Equal(WithoutId(before), WithoutId(source.SaveRewrite()));
    }

    [Fact]
    public void ABookletPadsToAMultipleOfFourPagesTwoToASheet()
    {
        var source = PdfDocument.Open(Pdfs.Text(5));

        var sheets = new PrintLayout(Booklet: true).Sheets(source, [0, 1, 2, 3, 4], 612, 792);

        Assert.Equal(4, sheets.Count);
        var first = PdfDocument.Open(sheets.Bytes).Pages[0];
        Assert.True(first.MediaBox.Width > first.MediaBox.Height);
    }

    [Fact]
    public void ALinkIsCountedAsLeftOff()
    {
        Assert.Null(PrintLayout.DroppedNote(0));
        Assert.Equal("1 link or note without a picture was left off the sheets.", PrintLayout.DroppedNote(1));
    }

    [Fact]
    public void ReverseAloneIsNotPlain()
    {
        var layout = new PrintLayout(Reverse: true);

        Assert.False(layout.IsPlain);
        Assert.Equal([3, 2, 1, 0], layout.Pages(null, 4));
    }

    [Fact]
    public void ALayoutLeavesTheRangeToTheSides()
    {
        var layout = new PrintLayout(PerSheet: 2, Parity: PrintParity.Odd, Reverse: true);

        Assert.Equal([2, 3, 4, 5], layout.Pages([2, 3, 4, 5], 8));
    }

    [Fact]
    public void OddSidesOfABookletAreTheFronts()
    {
        var booklet = new PrintLayout(Booklet: true, Parity: PrintParity.Odd);

        Assert.Equal([0, 2], booklet.SheetsToPrint(booklet.SideCount(8)));
        Assert.Equal([1, 3], new PrintLayout(Booklet: true, Parity: PrintParity.Even).SheetsToPrint(4));
    }

    [Fact]
    public void AnOddRunNeedsNoBlankButAnEvenRunOfAnOddCountEndsWithOne()
    {
        Assert.Equal([0, 2, 4], new PrintLayout(PerSheet: 2, Parity: PrintParity.Odd).SheetsToPrint(5));
        Assert.Equal([1, 3, -1], new PrintLayout(PerSheet: 2, Parity: PrintParity.Even).SheetsToPrint(5));
        Assert.Equal([1, 3], new PrintLayout(PerSheet: 2, Parity: PrintParity.Even).SheetsToPrint(4));
        Assert.Equal([-1, 3, 1], new PrintLayout(PerSheet: 2, Parity: PrintParity.Even, Reverse: true).SheetsToPrint(5));
        Assert.Equal([4, 3, 2, 1, 0], new PrintLayout(PerSheet: 2, Reverse: true).SheetsToPrint(5));
    }

    [Fact]
    public void APlainEvenRunOfAnOddCountEndsWithABlank()
    {
        Assert.Equal([1, 3, -1], new PrintLayout(Parity: PrintParity.Even).Pages(null, 5));
        Assert.Equal([-1, 3, 1], new PrintLayout(Parity: PrintParity.Even, Reverse: true).Pages(null, 5));
        Assert.Equal([1, 3], new PrintLayout(Parity: PrintParity.Even).Pages(null, 4));
        Assert.Empty(new PrintLayout(Parity: PrintParity.Even).Pages(null, 1));
        Assert.Equal([0, 2, 4], new PrintLayout(Parity: PrintParity.Odd).Pages(null, 5));
    }

    [Fact]
    public void ABookletNeverGetsABlank()
    {
        var booklet = new PrintLayout(Booklet: true, Parity: PrintParity.Even);

        Assert.Equal([1, 3, 5], booklet.SheetsToPrint(booklet.SideCount(11)));
    }

    [Fact]
    public void TheSideCountMatchesWhatImposeMakes()
    {
        var layouts = new[] { new PrintLayout(Booklet: true) }.Concat(PrintLayout.PerSheetChoices.Where(p => p > 1).Select(p => new PrintLayout(PerSheet: p)));
        foreach (var layout in layouts)
        {
            Assert.Equal(0, layout.SideCount(0));
            for (int n = 1; n <= 20; n++)
            {
                var result = PageOperations.Impose(PdfDocument.Open(Pdfs.Text(n)), Enumerable.Range(0, n).ToList(), layout.Options(612, 792));
                Assert.Equal(result.Sheets, layout.SideCount(n));
            }
        }
        Assert.Equal(7, new PrintLayout().SideCount(7));
    }

    [Fact]
    public void AGapTooWideForTheSheetIsRefused()
    {
        Assert.Null(new PrintLayout(PerSheet: 4, Gap: 10).Validate(612, 792));
        Assert.NotNull(new PrintLayout(PerSheet: 4, Gap: 300).Validate(612, 792));
        Assert.NotNull(new PrintLayout(Booklet: true, Gap: 270).Validate(612, 792));
        Assert.Null(new PrintLayout(Gap: 900).Validate(612, 792));
    }

    [Fact]
    public void TheTicketIsOneSidedForHalfAJobAndShortEdgeForABooklet()
    {
        System.Printing.Duplexing[] both = [System.Printing.Duplexing.OneSided, System.Printing.Duplexing.TwoSidedShortEdge];

        Assert.Equal(System.Printing.Duplexing.OneSided, new PrintLayout(Parity: PrintParity.Even).Duplex(both));
        Assert.Equal(System.Printing.Duplexing.TwoSidedShortEdge, new PrintLayout(Booklet: true).Duplex(both));
        Assert.Null(new PrintLayout(Booklet: true).Duplex([]));
        Assert.Null(new PrintLayout(PerSheet: 2).Duplex(both));
    }

    [Fact]
    public void ReversingAllSidesIsOneSidedSoNoPaperComesOutInsideOut()
    {
        System.Printing.Duplexing[] both = [System.Printing.Duplexing.OneSided, System.Printing.Duplexing.TwoSidedShortEdge];

        Assert.Equal(System.Printing.Duplexing.OneSided, new PrintLayout(Booklet: true, Reverse: true).Duplex(both));
        Assert.Equal(System.Printing.Duplexing.OneSided, new PrintLayout(PerSheet: 2, Reverse: true).Duplex([]));
    }

    [Fact]
    public void OnlyThePerSheetBookletGapAndBorderAreRemembered()
    {
        using var dir = new TempDir();
        var chosen = new PrintLayout(PerSheet: 4, Booklet: true, Parity: PrintParity.Even, Reverse: true, RightToLeft: true, Gap: 14.2, Border: true);
        AppPreferencesStore.Update(chosen.Remember, dir.Path);

        var back = PrintLayout.Remembered(AppPreferencesStore.Load(dir.Path));

        Assert.Equal(new PrintLayout(PerSheet: 4, Booklet: true, Gap: 14.2, Border: true), back);
    }

    [Fact]
    public void ARememberedValueOutOfRangeFallsBack()
    {
        var back = PrintLayout.Remembered(new AppPreferences { PrintPerSheet = 5, PrintGap = 500 });

        Assert.Equal(1, back.PerSheet);
        Assert.Equal(PrintLayout.MaxGap, back.Gap);
    }

    [Fact]
    public void ThePlainSummaryCountsPages()
    {
        Assert.Equal("8 pages.", new PrintLayout().Summary(null, 8));
        Assert.Equal("1 page.", new PrintLayout().Summary(null, 1));
        Assert.Equal("3 pages. In reverse order.", new PrintLayout(Reverse: true).Summary([2, 3, 4], 8));
    }

    [Fact]
    public void ALayoutSummaryCountsSidesAndPapers()
    {
        Assert.Equal("8 pages: 4 sides on 2 pieces of paper.", new PrintLayout(Booklet: true).Summary(null, 8));
        Assert.Equal("1 page: 1 side on 1 piece of paper.", new PrintLayout(PerSheet: 2).Summary(null, 1));
        Assert.Equal("8 pages: 4 sides on 2 pieces of paper. Odd sides (fronts): 2 of 4.", new PrintLayout(Booklet: true, Parity: PrintParity.Odd).Summary(null, 8));
        Assert.Equal("6 pages: 2 sides on 1 piece of paper. Even sides (backs): 1 of 2.", new PrintLayout(PerSheet: 4, Parity: PrintParity.Even).Summary([1, 2, 3, 4, 5, 6], 20));
    }

    [Fact]
    public void TheSummaryNamesTheBlankOfAnOddCount()
    {
        Assert.Equal("5 pages: 3 sides on 2 pieces of paper. Even sides (backs): 1 of 3. 3 sides: a blank is added at the end of the even run so each back meets its front.",
            new PrintLayout(PerSheet: 2, Parity: PrintParity.Even).Summary(null, 5));
        Assert.Contains("at the start of the even run", new PrintLayout(PerSheet: 2, Parity: PrintParity.Even, Reverse: true).Summary(null, 5));
        Assert.DoesNotContain("blank", new PrintLayout(PerSheet: 2, Parity: PrintParity.Odd).Summary(null, 5));
    }

    [Fact]
    public void TheSummarySaysWhenNothingIsLeft()
    {
        Assert.Equal("1 page. No sides are left to print.", new PrintLayout(Parity: PrintParity.Even).Summary(null, 1));
    }

    [Fact]
    public void RightToLeftGapAndBorderGoToTheEngine()
    {
        var options = new PrintLayout(PerSheet: 2, RightToLeft: true, Gap: 6, Border: true).Options(612, 792);

        Assert.True(options.RightToLeft);
        Assert.True(options.Border);
        Assert.Equal(6, options.Gap);
    }
}
