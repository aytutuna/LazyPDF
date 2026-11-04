using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageGeometryTests
{
    // A 100 x 200 page whose crop box starts at (10, 20): the corners of the box are known on screen.
    private static readonly PdfRect Box = new(10, 20, 110, 220);

    [Theory]
    [InlineData(0, 10, 20, 0, 200)]     // user bottom-left is the bottom-left of the screen
    [InlineData(0, 110, 220, 100, 0)]   // user top-right is the top-right
    [InlineData(90, 10, 20, 0, 0)]      // turned clockwise, the bottom-left corner goes to the top-left
    [InlineData(90, 10, 220, 200, 0)]   // and the top-left goes to the top-right
    [InlineData(180, 10, 20, 100, 0)]
    [InlineData(180, 110, 220, 0, 200)]
    [InlineData(270, 10, 20, 200, 100)] // bottom-left goes to the bottom-right
    [InlineData(270, 10, 220, 0, 100)]  // top-left goes to the bottom-left
    public void CornersLandWhereARotatedPageShowsThem(int rotate, double x, double y, double dx, double dy)
    {
        var geometry = new PageGeometry(Box, rotate);
        var (px, py) = geometry.ToDisplay(x, y);
        Assert.Equal(dx, px, 9);
        Assert.Equal(dy, py, 9);
    }

    [Theory]
    [InlineData(0, 100, 200)]
    [InlineData(90, 200, 100)]
    [InlineData(180, 100, 200)]
    [InlineData(270, 200, 100)]
    public void SizeFollowsTheRotation(int rotate, double width, double height)
    {
        var geometry = new PageGeometry(Box, rotate);
        Assert.Equal(width, geometry.Width);
        Assert.Equal(height, geometry.Height);
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(90, 1)]
    [InlineData(180, 2.5)]
    [InlineData(270, 0.5)]
    public void ToUserUndoesToDisplay(int rotate, double unit)
    {
        var geometry = new PageGeometry(Box, rotate, unit);
        foreach (var (x, y) in new[] { (10.0, 20.0), (55.5, 100.25), (110.0, 220.0), (-30.0, 400.0) })
        {
            var (dx, dy) = geometry.ToDisplay(x, y);
            var (ux, uy) = geometry.ToUser(dx, dy);
            Assert.Equal(x, ux, 9);
            Assert.Equal(y, uy, 9);
        }
    }

    [Fact]
    public void UserUnitScalesTheDisplay()
    {
        var geometry = new PageGeometry(Box, 0, 2);
        Assert.Equal(200, geometry.Width);
        Assert.Equal(400, geometry.Height);
        var (x, y) = geometry.ToDisplay(60, 120);
        Assert.Equal(100, x);
        Assert.Equal(200, y);
    }

    [Fact]
    public void RectanglesCrossInBothDirections()
    {
        var geometry = new PageGeometry(Box, 90);
        var shown = geometry.ToDisplay(new PdfRect(10, 20, 50, 40));
        Assert.Equal(new DisplayRect(0, 0, 20, 40), shown);
        Assert.Equal(new PdfRect(10, 20, 50, 40), geometry.ToUser(shown));
    }

    [Fact]
    public void PageGeometryReadsThePage()
    {
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R>>")
            .Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
            .Obj(3, "<</Type /Page /MediaBox [0 0 600 800] /CropBox [100 100 400 300] /Rotate 90 /UserUnit 2>>");
        var page = PdfDocument.Open(pdf.Finish()).Pages[0];
        var geometry = new PageGeometry(page);
        Assert.Equal(400, geometry.Width);
        Assert.Equal(600, geometry.Height);
        Assert.Equal(90, geometry.Rotation);
        var (x, y) = geometry.ToDisplay(100, 100);
        Assert.Equal((0, 0), (x, y));
    }

    [Fact]
    public void RotationIsKeptToAMultipleOf90()
    {
        Assert.Equal(270, new PageGeometry(Box, -90).Rotation);
        Assert.Equal(90, new PageGeometry(Box, 450).Rotation);
    }
}
