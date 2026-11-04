// From Lazy Print's CardGridInsets.cs.
using System.Windows;

namespace LazyPDF.App;

/// <summary>
/// Side insets for the start screen's tile grid. The width left over after the
/// last whole column is split between both sides, so the grid sits centred instead of leaving
/// a dead gutter on the right, and the tab's header lines up with the grid's outer card edges.
/// </summary>
internal static class GridInsets
{
    /// <summary>Card width (200) plus its margin (6) on both sides.</summary>
    public const double CardSlotWidth = 200 + 2 * CardMargin;
    /// <summary>The margin around each card.</summary>
    public const double CardMargin = 6;
    /// <summary>Minimum space between the view edge and the first card slot.</summary>
    public const double EdgeMargin = 10;

    /// <summary>
    /// Number of card columns that fit in <paramref name="width"/>, keeping room for a vertical
    /// scrollbar, so the column count does not flip when one appears.
    /// </summary>
    public static int Columns(double width, double slotWidth = CardSlotWidth) =>
        Math.Max(1, (int)((width - 2 * EdgeMargin - SystemParameters.VerticalScrollBarWidth) / slotWidth));

    /// <summary>
    /// Left/right insets for the card grid and for the header above it, for a grid laid out in
    /// <paramref name="width"/> with <paramref name="columns"/> columns (by default as many as
    /// fit) of <paramref name="slotWidth"/> each (the start screen's tiles are narrower than the
    /// cards). Top and bottom are left at 0 for the caller to fill in.
    /// </summary>
    public static (Thickness Cards, Thickness Header) For(double width, int? columns = null, double slotWidth = CardSlotWidth)
    {
        double usable = Math.Max(0, width - 2 * EdgeMargin);
        double leftover = usable - (columns ?? Columns(width, slotWidth)) * slotWidth;
        // Whole DIPs, rounded down, so the grid never ends up a hair too narrow for its columns.
        double side = EdgeMargin + Math.Max(0, Math.Floor(leftover / 2));
        return (new Thickness(side, 0, side, 0),
                new Thickness(side + CardMargin, 0, side + CardMargin, 0));
    }
}
