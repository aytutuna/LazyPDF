using System.Windows;
using LazyPDF.App.Tools.EditContent;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Edit;

// The geometry of the selection handles, and the look the typed text takes from the run it replaces.
public sealed class EditSurfaceTests
{
    private static readonly Rect Box = new(100, 100, 200, 100);

    [Theory]
    [InlineData(0, 100, 100)]
    [InlineData(1, 200, 100)]
    [InlineData(2, 300, 100)]
    [InlineData(3, 300, 150)]
    [InlineData(4, 300, 200)]
    [InlineData(5, 200, 200)]
    [InlineData(6, 100, 200)]
    [InlineData(7, 100, 150)]
    public void EveryHandleIsFoundWhereItIsDrawn(int handle, double x, double y)
    {
        Assert.Equal(handle, EditSurface.HandleAt(Box, new Point(x + 1, y - 1), 1));
    }

    [Fact]
    public void ThePointerAwayFromTheHandlesFindsNone()
    {
        Assert.Equal(-1, EditSurface.HandleAt(Box, new Point(200, 150), 1));
    }

    [Fact]
    public void TheReachOfAHandleShrinksWithTheZoom()
    {
        Assert.Equal(-1, EditSurface.HandleAt(Box, new Point(106, 100), 2));
        Assert.Equal(0, EditSurface.HandleAt(Box, new Point(106, 100), 1));
    }

    [Fact]
    public void DraggingTheRightSideWidensTheBoxAndHoldsTheLeft()
    {
        var resized = EditSurface.Resize(Box, 3, new Point(350, 999), square: false);

        Assert.Equal(new Rect(100, 100, 250, 100), resized);
    }

    [Fact]
    public void ACornerKeepsTheProportionsUnlessShiftIsDown()
    {
        var square = EditSurface.Resize(Box, 4, new Point(500, 150), square: true);
        var free = EditSurface.Resize(Box, 4, new Point(500, 150), square: false);

        Assert.Equal(new Rect(100, 100, 400, 200), square);
        Assert.Equal(new Rect(100, 100, 400, 50), free);
    }

    [Fact]
    public void ADragPastTheOppositeSideLeavesASliverNotAFlippedBox()
    {
        var resized = EditSurface.Resize(Box, 0, new Point(900, 900), square: false);

        Assert.True(resized.Width > 0 && resized.Height > 0);
        Assert.Equal(Box.Right, resized.Right);
        Assert.Equal(Box.Bottom, resized.Bottom);
    }

    [Fact]
    public void WithNoFontTheTypedTextIsInArial()
    {
        Assert.Equal("Arial", EditorLook.FamilyOf(null).Source);
        Assert.Equal("", EditorLook.NameOf(null));
    }

    [Fact]
    public void EveryColourOfThePaletteHasANameAndTheyAreDistinct()
    {
        Assert.All(Palette.Colors, c => Assert.False(string.IsNullOrWhiteSpace(c.Name)));
        Assert.Equal(Palette.Colors.Count, Palette.Colors.Select(c => c.Color).Distinct().Count());
    }
}
