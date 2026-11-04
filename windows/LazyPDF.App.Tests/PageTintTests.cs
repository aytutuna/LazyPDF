using System.Windows.Media;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The tint is on the pixels shown, never on the file.
public sealed class PageTintTests
{
    private static byte[] One(byte r, byte g, byte b) => [r, g, b, 255];

    [Fact]
    public void NoTintOnlyReordersTheChannels()
    {
        Assert.Equal([30, 20, 10, 255], PageTints.ToBgra(One(10, 20, 30), PageTint.None));
    }

    [Fact]
    public void DarkMakesWhitePaperDarkAndBlackInkLight()
    {
        var white = PageTints.ToBgra(One(255, 255, 255), PageTint.Dark);
        var black = PageTints.ToBgra(One(0, 0, 0), PageTint.Dark);

        Assert.InRange(white[0], 20, 60);
        Assert.InRange(black[0], 200, 240);
        Assert.InRange(white[1], 20, 60);
        Assert.InRange(white[2], 20, 60);
    }

    [Fact]
    public void DarkKeepsAColourItsHue()
    {
        var red = PageTints.ToBgra(One(220, 30, 30), PageTint.Dark);

        Assert.True(red[2] > red[1] && red[2] > red[0]);
    }

    [Fact]
    public void SepiaMakesWhitePaperThePaperColourAndBlackStaysBlack()
    {
        var paper = PageTints.ToBgra(One(255, 255, 255), PageTint.Sepia);
        var ink = PageTints.ToBgra(One(0, 0, 0), PageTint.Sepia);

        Assert.Equal([216, 236, 244, 255], paper);
        Assert.Equal([0, 0, 0, 255], ink);
    }

    [Fact]
    public void ATileBecomesAFrozenBitmapOfTheSameSize()
    {
        var bitmap = PageTints.ToBitmap(new PdfRgbaImage(3, 2, new byte[3 * 2 * 4]), PageTint.None);

        Assert.True(bitmap.IsFrozen);
        Assert.Equal((3, 2), (bitmap.PixelWidth, bitmap.PixelHeight));
    }

    [Fact]
    public void ThePaperBeforeThePicturesArriveMatchesTheTint()
    {
        Assert.Equal(Colors.White, PageTints.Paper(PageTint.None));
        Assert.Equal(Color.FromRgb(0x1C, 0x1C, 0x1C), PageTints.Paper(PageTint.Dark));
        Assert.Equal(Color.FromRgb(0xF4, 0xEC, 0xD8), PageTints.Paper(PageTint.Sepia));
    }
}
