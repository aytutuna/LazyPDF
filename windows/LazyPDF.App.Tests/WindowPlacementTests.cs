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
    public void ASizeLargerThanTheScreensIsCut()
    {
        var fitted = MainWindow.Fit(new Rect(0, 0, 1200, 900), new Rect(0, 0, 1366, 768), Primary);

        Assert.Equal(1200, fitted.Width);
        Assert.Equal(768, fitted.Height);
    }

    [Fact]
    public void AWindowOnALargerSecondMonitorKeepsItsSize()
    {
        var saved = new Rect(1400, 50, 2400, 1300);

        Assert.Equal(saved, MainWindow.Fit(saved, new Rect(0, 0, 4480, 1440), new Rect(0, 0, 1280, 688)));
    }

    [Fact]
    public void AWindowOffEveryScreenIsCentredAndCutToTheWorkArea()
    {
        var fitted = MainWindow.Fit(new Rect(9000, 9000, 2400, 1300), new Rect(0, 0, 4480, 1440), new Rect(0, 0, 1280, 688));

        Assert.Equal(new Rect(0, 0, 1280, 688), fitted);
    }

    [Fact]
    public void AMaximisedWindowIsSavedWithItsRestoreBounds()
    {
        var placement = MainWindow.PlacementOf(true, new Rect(0, 0, 1366, 728), new Rect(100, 80, 900, 600));

        Assert.True(placement.Maximized);
        Assert.Equal((100, 80, 900, 600), (placement.Left, placement.Top, placement.Width, placement.Height));
    }

    [Fact]
    public void ANormalWindowIsSavedWithItsCurrentBounds()
    {
        var placement = MainWindow.PlacementOf(false, new Rect(10, 20, 800, 600), new Rect(100, 80, 900, 600));

        Assert.False(placement.Maximized);
        Assert.Equal((10, 20, 800, 600), (placement.Left, placement.Top, placement.Width, placement.Height));
    }

    [Fact]
    public void AVisibleRectangleStaysWhereItIs()
    {
        var saved = new Rect(1500, 50, 900, 600);

        Assert.Equal(saved, MainWindow.Fit(saved, new Rect(0, 0, 3000, 1080), Primary));
    }

    [Fact]
    public void WideSavedPanesAreClampedInsideTheRoomWithTheInspectorFirst()
    {
        var (side, inspector) = MainWindow.PaneLimits(832, 700, 600, true, true);

        Assert.Equal(232, side);
        Assert.Equal(652, inspector);
    }

    [Fact]
    public void ThePaneLimitsDoNotDependOnTheLastLayout()
    {
        Assert.Equal(MainWindow.PaneLimits(832, 700, 600, true, true), MainWindow.PaneLimits(832, 700, 600, true, true));
        Assert.Equal((552d, 652d), MainWindow.PaneLimits(832, 300, 280, true, true));
    }

    [Fact]
    public void AHiddenPaneLeavesItsRoomToTheOther()
    {
        var (side, inspector) = MainWindow.PaneLimits(832, 700, 600, true, false);

        Assert.Equal(832, side);
        Assert.Equal(652, inspector);
        Assert.Equal(832, MainWindow.PaneLimits(832, 700, 600, false, true).Inspector);
    }

    [Fact]
    public void ATinyRoomStillKeepsEachPaneItsMinimum()
    {
        Assert.Equal((180d, 180d), MainWindow.PaneLimits(100, 400, 400, true, true));
    }
}
