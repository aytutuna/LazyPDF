using System.Reflection;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Tools.Measure;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The pointer tool against a viewer that answers only what it is asked: where a page is on screen, its words and its geometry.
public sealed class MeasureToolTests
{
    private static readonly MeasureScale Inches = new(1, LengthUnit.Inch, 1, LengthUnit.Inch);

    private class Viewer : DispatchProxy
    {
        public double Zoom { get; set; } = 2;
        public TextPage? Text { get; set; }
        public PageGeometry Geometry { get; set; } = null!;

        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        {
            "PageToView" => new Matrix(Zoom, 0, 0, Zoom, 0, 0),
            "GetTextAsync" => Task.FromResult(Text),
            "Geometry" => Geometry,
            _ => throw new NotSupportedException(method.Name),
        };
    }

    private static (MeasureTool Tool, List<MeasureItem> Done, Viewer Viewer) Start(MeasureKind kind, bool withText = false)
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var proxy = DispatchProxy.Create<IDocumentViewer, Viewer>();
        var viewer = (Viewer)(object)proxy;
        viewer.Geometry = new PageGeometry(document.Pages[0]);
        if (withText) viewer.Text = TextPage.Create(document, document.Pages[0]);
        var tool = new MeasureTool(proxy) { Kind = kind };
        var done = new List<MeasureItem>();
        tool.Finished += done.Add;
        return (tool, done, viewer);
    }

    private static PagePointer At(double x, double y, int clicks = 1, int page = 0, ModifierKeys keys = ModifierKeys.None) =>
        new(page, new Point(x, y), new Point(x * 2, y * 2), Pressed: clicks > 0, clicks, keys);

    [Fact]
    public void TwoClicksMakeADistance()
    {
        var (tool, done, _) = Start(MeasureKind.Distance);

        tool.Press(At(0, 0));
        Assert.Empty(done);
        tool.Press(At(72, 0));

        var item = Assert.Single(done);
        Assert.Equal(MeasureKind.Distance, item.Kind);
        Assert.Equal("1 in", item.Value(Inches));
        Assert.Empty(tool.Points);
    }

    [Fact]
    public void ADoubleClickEndsAnAreaWithoutAddingTheCornerTwice()
    {
        var (tool, done, _) = Start(MeasureKind.Area);

        tool.Press(At(0, 0));
        tool.Press(At(72, 0));
        Assert.False(tool.CanFinish);
        tool.Press(At(72, 72));
        Assert.True(tool.CanFinish);
        tool.Press(At(72, 72, clicks: 2));

        var item = Assert.Single(done);
        Assert.Equal(3, item.Points.Count);
        Assert.Equal("0.5 in²", item.Value(Inches).Replace(",", "."));
    }

    [Fact]
    public void ClickingTheFirstCornerAgainClosesTheShape()
    {
        var (tool, done, _) = Start(MeasureKind.Perimeter);

        tool.Press(At(0, 0));
        tool.Press(At(72, 0));
        tool.Press(At(72, 72));
        tool.Press(At(0, 72));
        tool.Press(At(1, 1));

        Assert.Equal("4 in", Assert.Single(done).Value(Inches));
    }

    [Fact]
    public void EscapeDropsTheShapeAndAClickOnAnotherPageWaitsForIt()
    {
        var (tool, done, _) = Start(MeasureKind.Area);

        tool.Press(At(0, 0));
        tool.Press(At(72, 0));
        tool.Cancel();
        Assert.Empty(tool.Points);

        tool.Press(At(0, 0));
        tool.Press(At(5, 5, page: 1));
        Assert.Equal(0, tool.Page);
        Assert.Single(tool.Points);
        Assert.Empty(done);
    }

    [Fact]
    public void UndoTakesBackTheLastCornerAndTheLastOneFreesThePage()
    {
        var (tool, _, _) = Start(MeasureKind.Area);

        tool.Press(At(0, 0));
        tool.Press(At(72, 0));
        tool.Undo();
        Assert.Single(tool.Points);
        tool.Undo();

        Assert.Empty(tool.Points);
        Assert.Equal(-1, tool.Page);
    }

    [Fact]
    public void ADoubleClickInADistanceDoesNotMakeAZeroLengthLine()
    {
        var (tool, done, _) = Start(MeasureKind.Distance);

        tool.Press(At(10, 10));
        tool.Press(At(10, 10, clicks: 2));
        Assert.Empty(done);
        Assert.Single(tool.Points);

        tool.Press(At(82, 10));
        Assert.Equal("1 in", Assert.Single(done).Value(Inches));
    }

    [Fact]
    public void ShiftKeepsTheNextPointOnAStraightLine()
    {
        var (tool, done, _) = Start(MeasureKind.Distance);

        tool.Press(At(10, 10));
        tool.Press(At(82, 13, keys: ModifierKeys.Shift));

        var end = Assert.Single(done).Points[1];
        Assert.Equal(10, end.Y, 6);
    }

    [Fact]
    public void ClicksSnapToTheCornersOfWordsWhileSnappingIsOn()
    {
        var (tool, done, viewer) = Start(MeasureKind.Distance, withText: true);
        var word = viewer.Text!.Words[0];
        var corner = viewer.Geometry.ToDisplay(word.Bounds.Left, word.Bounds.Top);

        tool.Press(At(corner.X + 2, corner.Y - 2));
        tool.Press(At(300, 300));

        var start = Assert.Single(done).Points[0];
        Assert.Equal(corner.X, start.X, 6);
        Assert.Equal(corner.Y, start.Y, 6);
    }

    [Fact]
    public void WithSnappingOffTheClickStaysWhereItWas()
    {
        var (tool, done, viewer) = Start(MeasureKind.Distance, withText: true);
        tool.Snap = false;
        var word = viewer.Text!.Words[0];
        var corner = viewer.Geometry.ToDisplay(word.Bounds.Left, word.Bounds.Top);

        tool.Press(At(corner.X + 2, corner.Y - 2));
        tool.Press(At(300, 300));

        Assert.Equal(corner.X + 2, Assert.Single(done).Points[0].X, 6);
    }
}
