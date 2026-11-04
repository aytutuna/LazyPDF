using System.Windows;

namespace LazyPDF.App.Viewer;

/// <summary>What the zoom of a view is kept to, and the zooms that fit a page to the window.</summary>
public static class ZoomMath
{
    public const double MaxZoom = 64;

    // Positions in the scrolled area are floats in WPF's layout; past a few million pixels a pixel is no longer exact.
    private const double MaxExtent = 4_000_000;

    private static readonly double[] Steps = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64];

    /// <summary>The smallest and largest zoom for pages whose longest side is <paramref name="longestSide"/> points.</summary>
    public static (double Min, double Max) Limits(double longestSide, double pixelsPerDip)
    {
        double side = Math.Max(longestSide, 1) * PageSpace.DipPerPoint;
        return (Math.Min(0.05, 200 / side), Math.Min(MaxZoom, MaxExtent / pixelsPerDip / side));
    }

    public static double Clamp(double zoom, (double Min, double Max) limits) => Math.Clamp(zoom, limits.Min, limits.Max);

    /// <summary>The zoom at which a spread <paramref name="spreadWidth"/> points wide fills <paramref name="viewport"/>.</summary>
    public static double FitWidth(double spreadWidth, Size viewport) =>
        Math.Max(0, viewport.Width - 2 * ViewLayout.Margin) / Math.Max(spreadWidth, 1) / PageSpace.DipPerPoint;

    /// <summary>The zoom at which a whole spread shows in <paramref name="viewport"/>.</summary>
    public static double FitPage(Size spread, Size viewport) =>
        Math.Min(FitWidth(spread.Width, viewport), Math.Max(0, viewport.Height - 2 * ViewLayout.Margin) / Math.Max(spread.Height, 1) / PageSpace.DipPerPoint);

    /// <summary>The next zoom of the usual steps above or below <paramref name="zoom"/>.</summary>
    public static double Step(double zoom, int direction)
    {
        if (direction > 0)
        {
            foreach (double s in Steps)
            {
                if (s > zoom * 1.001) return s;
            }
            return Steps[^1];
        }
        for (int i = Steps.Length - 1; i >= 0; i--)
        {
            if (Steps[i] < zoom / 1.001) return Steps[i];
        }
        return Steps[0];
    }
}
