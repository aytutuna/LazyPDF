using System.Windows;
using LazyPDF.App.Tools.Compare;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Where a place found by the pixel comparison lies on the old page, and what the rows of document differences say.
public sealed class CompareRowTests
{
    private static PageGeometry Page(double width, double height) => new(new PdfRect(0, 0, width, height), 0);

    [Fact]
    public void ABiggerOldPageScalesTheBox()
    {
        var box = ChangeRow.OldBox(new Rect(10, 20, 30, 40), new PixelAlignment(0, 0, 0), 96, Page(200, 300), Page(100, 150));

        Assert.Equal(new Rect(20, 40, 60, 80), box);
    }

    [Fact]
    public void AShiftedRescanMovesTheBoxBack()
    {
        var box = ChangeRow.OldBox(new Rect(10, 20, 30, 40), new PixelAlignment(8, -16, 0), 96, Page(100, 150), Page(100, 150));

        Assert.Equal(new Rect(4, 32, 30, 40), box);
    }

    [Fact]
    public void ATurnedPageKeepsTheCentreWhereItIs()
    {
        var box = ChangeRow.OldBox(new Rect(45, 45, 10, 10), new PixelAlignment(0, 0, 90), 96, Page(100, 100), Page(100, 100));

        Assert.Equal(50, box.Left + box.Width / 2, 6);
        Assert.Equal(50, box.Top + box.Height / 2, 6);
    }

    [Fact]
    public void AFormValueShowsInTheRow()
    {
        using var session = CompareKit.Session(CompareKit.Before(), CompareKit.After());

        var row = Assert.Single(session.Rows(Parts.Forms));

        Assert.True(row.OldPage < 0 && row.NewPage < 0);
        Assert.Contains("Ann", row.Subtitle);
    }
}
