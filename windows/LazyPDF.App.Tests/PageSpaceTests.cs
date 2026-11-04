using System.Windows;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

// Page space to the view and back, for every rotation the viewer has.
public sealed class PageSpaceTests
{
    private static readonly Size Page = new(200, 300);

    [Theory]
    [InlineData(0, 0, 0, 10, 20)]
    [InlineData(90, 0, 0, 310, 20)]
    [InlineData(180, 0, 0, 210, 320)]
    [InlineData(270, 0, 0, 10, 220)]
    public void TheTopLeftOfThePageLandsWhereTheRotationPutsIt(int rotation, double x, double y, double viewX, double viewY)
    {
        var m = PageSpace.ToView(Page, rotation, 1, new Point(10, 20));

        var at = m.Transform(new Point(x, y));

        Assert.Equal(viewX, at.X, 6);
        Assert.Equal(viewY, at.Y, 6);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void TheBottomRightOfThePageIsTheOppositeCornerOfTheShownRectangle(int rotation)
    {
        var origin = new Point(40, 50);
        var shown = PageSpace.Shown(Page, rotation, 2);
        var m = PageSpace.ToView(Page, rotation, 2, origin);

        var box = new Rect(m.Transform(new Point(0, 0)), m.Transform(new Point(200, 300)));

        Assert.Equal(origin.X, box.Left, 6);
        Assert.Equal(origin.Y, box.Top, 6);
        Assert.Equal(shown.Width, box.Width, 6);
        Assert.Equal(shown.Height, box.Height, 6);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void AViewPointComesBackToThePointOfThePage(int rotation)
    {
        var m = PageSpace.ToView(Page, rotation, 1.7, new Point(13, 29));
        var back = PageSpace.ToPage(m);

        foreach (var p in new[] { new Point(0, 0), new Point(50, 120.5), new Point(200, 300), new Point(-20, 400) })
        {
            var again = back.Transform(m.Transform(p));
            Assert.Equal(p.X, again.X, 6);
            Assert.Equal(p.Y, again.Y, 6);
        }
    }

    [Theory]
    [InlineData(0, 200, 300)]
    [InlineData(90, 300, 200)]
    [InlineData(180, 200, 300)]
    [InlineData(270, 300, 200)]
    public void ASidewaysRotationSwapsTheShownSize(int rotation, double width, double height)
    {
        var size = PageSpace.Shown(Page, rotation, 1);

        Assert.Equal(width, size.Width);
        Assert.Equal(height, size.Height);
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(90, 90)]
    [InlineData(-90, 270)]
    [InlineData(360, 0)]
    [InlineData(450, 90)]
    [InlineData(100, 90)]
    public void ARotationIsKeptToTheNearestRightAngle(int degrees, int expected) =>
        Assert.Equal(expected, PageSpace.NormalizeRotation(degrees));

    [Fact]
    public void ARectangleIsTakenToItsBoundingRectangle()
    {
        var m = PageSpace.ToView(Page, 90, 1, new Point(0, 0));

        var box = PageSpace.Transform(m, new Rect(10, 20, 30, 40));

        Assert.Equal(new Rect(240, 10, 40, 30), box);
    }
}
