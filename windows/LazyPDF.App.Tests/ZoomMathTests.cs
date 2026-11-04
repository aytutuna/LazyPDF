using System.Windows;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

// The zoom limits, the steps and the zooms that fit a page to the window.
public sealed class ZoomMathTests
{
    [Fact]
    public void FittingTheWidthFillsTheViewportLessTheMargins()
    {
        double zoom = ZoomMath.FitWidth(600, new Size(1000, 800));

        double shown = 600 * zoom * PageSpace.DipPerPoint;
        Assert.Equal(1000 - 2 * ViewLayout.Margin, shown, 6);
    }

    [Fact]
    public void FittingThePageIsLimitedByTheTighterSide()
    {
        var tall = new Size(600, 3000);

        double zoom = ZoomMath.FitPage(tall, new Size(1000, 800));

        Assert.Equal((800 - 2 * ViewLayout.Margin) / 3000 / PageSpace.DipPerPoint, zoom, 6);
        Assert.True(zoom < ZoomMath.FitWidth(600, new Size(1000, 800)));
    }

    [Fact]
    public void TheStepsGoUpAndDownTheUsualScale()
    {
        Assert.Equal(1.25, ZoomMath.Step(1, 1));
        Assert.Equal(0.75, ZoomMath.Step(1, -1));
        Assert.Equal(2, ZoomMath.Step(1.7, 1));
        Assert.Equal(1.5, ZoomMath.Step(1.7, -1));
        Assert.Equal(ZoomMath.MaxZoom, ZoomMath.Step(ZoomMath.MaxZoom, 1));
        Assert.Equal(0.05, ZoomMath.Step(0.05, -1));
    }

    [Fact]
    public void TheLimitsLeaveRoomForAHugePage()
    {
        var (min, max) = ZoomMath.Limits(14_400, 1);

        Assert.True(min < 0.02);
        Assert.Equal(ZoomMath.MaxZoom, max);
    }

    [Fact]
    public void ADenseScreenAndAHugePageLowerTheCeiling()
    {
        var (_, max) = ZoomMath.Limits(200_000, 2);

        Assert.True(max < ZoomMath.MaxZoom);
        Assert.True(200_000 * max * PageSpace.DipPerPoint * 2 <= 4_000_001);
    }

    [Fact]
    public void AZoomIsHeldInsideTheLimits()
    {
        var limits = ZoomMath.Limits(792, 1);

        Assert.Equal(limits.Min, ZoomMath.Clamp(0.0001, limits));
        Assert.Equal(limits.Max, ZoomMath.Clamp(1000, limits));
        Assert.Equal(1, ZoomMath.Clamp(1, limits));
    }
}
