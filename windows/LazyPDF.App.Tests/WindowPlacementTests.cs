using System.Windows;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class WindowPlacementTests
{
    private static readonly Rect Primary = new(0, 0, 1366, 728);

    [Fact]
    public void ARectangleOnAMissingMonitorIsBroughtBack()
    {
        var fitted = MainWindow.Fit(new Rect(2200, 100, 1000, 700), new Rect(0, 0, 1366, 768), Primary);

        Assert.Equal(new Rect(183, 14, 1000, 700), fitted);
    }

    [Fact]
    public void ASizeLargerThanTheWorkAreaIsCut()
    {
        var fitted = MainWindow.Fit(new Rect(0, 0, 1200, 800), new Rect(0, 0, 1366, 768), Primary);

        Assert.Equal(1200, fitted.Width);
        Assert.Equal(728, fitted.Height);
    }

    [Fact]
    public void AVisibleRectangleStaysWhereItIs()
    {
        var saved = new Rect(1500, 50, 900, 600);

        Assert.Equal(saved, MainWindow.Fit(saved, new Rect(0, 0, 3000, 1080), Primary));
    }
}
