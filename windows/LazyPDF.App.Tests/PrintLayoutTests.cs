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
        Assert.Equal([1, 3], new PrintLayout(Parity: PrintParity.Even).Pages(null, 5));
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
        Assert.Equal(before, source.SaveRewrite());
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
}
