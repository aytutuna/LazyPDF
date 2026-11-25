using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class PageInkTests
{
    private static PdfRgbaImage White(int w, int h)
    {
        var rgba = new byte[w * h * 4];
        Array.Fill(rgba, (byte)255);
        return new PdfRgbaImage(w, h, rgba);
    }

    private static void Black(PdfRgbaImage image, int left, int top, int width, int height)
    {
        for (int y = top; y < top + height; y++)
            for (int x = left; x < left + width; x++)
            {
                int i = (y * image.Width + x) * 4;
                image.Rgba[i] = image.Rgba[i + 1] = image.Rgba[i + 2] = 0;
            }
    }

    [Fact]
    public void AWhitePageHasNoInkAndIsBlank()
    {
        var image = White(100, 80);
        Assert.Null(PageInk.Bounds(image));
        Assert.True(PageInk.IsBlank(image));
    }

    [Fact]
    public void ABlockGivesItsExactRectangle()
    {
        var image = White(100, 80);
        Black(image, 30, 20, 20, 10);
        Assert.Equal((30, 20, 50, 30), PageInk.Bounds(image));
    }

    [Fact]
    public void ATransparentPageIsBlank()
    {
        var image = new PdfRgbaImage(100, 80, new byte[100 * 80 * 4]);
        Assert.Null(PageInk.Bounds(image));
        Assert.True(PageInk.IsBlank(image));
    }

    [Fact]
    public void SpecksOnTheBorderDoNotMoveTheBounds()
    {
        var image = White(100, 80);
        Black(image, 30, 20, 20, 10);
        Black(image, 0, 40, 1, 1);
        Black(image, 99, 5, 1, 1);
        Black(image, 60, 79, 1, 1);
        Assert.Equal((30, 20, 50, 30), PageInk.Bounds(image));
    }

    [Fact]
    public void InkOnOneRowGivesThatRow()
    {
        var image = White(100, 80);
        Black(image, 10, 40, 1, 1);
        Black(image, 60, 40, 1, 1);
        Assert.Equal((10, 40, 61, 41), PageInk.Bounds(image));
    }

    [Fact]
    public void InkAtTheTopAndBottomInDifferentColumnsDoesNotRunOut()
    {
        var image = White(100, 80);
        Black(image, 5, 10, 1, 1);
        Black(image, 30, 10, 1, 1);
        Black(image, 50, 60, 1, 1);
        Black(image, 70, 60, 1, 1);
        Assert.Equal((0, 10, 100, 61), PageInk.Bounds(image));
    }

    [Fact]
    public void AThinVerticalRuleIsNotEmpty()
    {
        var image = White(100, 80);
        Black(image, 40, 10, 1, 50);
        Assert.Equal((40, 10, 41, 60), PageInk.Bounds(image));
    }

    [Fact]
    public void AThinStrokeAboveTheTextStaysInTheBox()
    {
        var image = White(100, 80);
        Black(image, 30, 20, 20, 10);
        Black(image, 40, 10, 1, 10);
        Assert.Equal((30, 10, 50, 30), PageInk.Bounds(image));
    }

    [Fact]
    public void APageWithABlockOfInkIsNotBlank()
    {
        var image = White(595, 842);
        Black(image, 100, 100, 200, 50);
        Assert.False(PageInk.IsBlank(image));
    }

    [Fact]
    public void DarkShareOfAHalfBlackImageIsHalf()
    {
        var image = White(10, 10);
        Black(image, 0, 0, 10, 5);
        Assert.Equal(0.5, PageInk.DarkShare(image));
    }
}
