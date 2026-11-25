using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LazyPDF.App.Tests.Tools.Comment;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class TextEditorTests
{
    [Fact]
    public Task ABoxOpenedAtThePageEdgeStaysInsideIt() => Sta.Run(() =>
    {
        var overlay = new PageOverlay(0, new Size(200, 200));

        TextEditor.Open(overlay, new Rect(190, 190, 10, 10), 12, "", 0, _ => { });

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.True(Canvas.GetLeft(box) + box.Width <= 200);
        Assert.True(Canvas.GetTop(box) + box.MinHeight <= 200);
        Assert.True(box.MaxHeight <= 200 - Canvas.GetTop(box) || box.MaxHeight == box.MinHeight);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ALargeFontAtThePageBottomKeepsRoomForALine() => Sta.Run(() =>
    {
        var overlay = new PageOverlay(0, new Size(400, 600));

        TextEditor.Open(overlay, new Rect(10, 590, 100, 10), 72, "", 0, _ => { });

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.True(box.MinHeight >= 72);
        Assert.True(Canvas.GetTop(box) + box.MinHeight <= 600);
        return Task.CompletedTask;
    });

    private static TextBox InPlaceBox(bool wrap)
    {
        var viewer = ViewerStandIn.Create(out var stand);
        var look = new EditorLook(new FontFamily("Arial"), 12, Colors.Black, false, false, LazyPDF.Core.TextAlignment.Left);
        new InPlaceEditor(viewer).Open(0, new Rect(500, 800, 50, 20), "", look, wrap);
        return Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children));
    }

    [Fact]
    public Task AWrappedInPlaceBoxStaysInsideThePageAndScrolls() => Sta.Run(() =>
    {
        var box = InPlaceBox(true);

        Assert.Equal(95, box.MaxWidth);
        Assert.Equal(42, box.MaxHeight);
        Assert.Equal(ScrollBarVisibility.Auto, box.VerticalScrollBarVisibility);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnUnwrappedInPlaceBoxOnlyKeepsItsWidthInsideThePage() => Sta.Run(() =>
    {
        var box = InPlaceBox(false);

        Assert.Equal(95, box.MaxWidth);
        Assert.True(double.IsPositiveInfinity(box.MaxHeight));
        Assert.Equal(ScrollBarVisibility.Hidden, box.VerticalScrollBarVisibility);
        return Task.CompletedTask;
    });

    // The corners of a w x h box on the overlay once its own transform and position are applied
    internal static Rect Footprint(FrameworkElement box, double w, double h)
    {
        var to = new TranslateTransform(Canvas.GetLeft(box), Canvas.GetTop(box));
        var turn = box.RenderTransform ?? Transform.Identity;
        var pts = new[] { new Point(0, 0), new Point(w, 0), new Point(0, h), new Point(w, h) }
            .Select(p => to.Transform(turn.Transform(p))).ToArray();
        return new Rect(new Point(pts.Min(p => p.X), pts.Min(p => p.Y)), new Point(pts.Max(p => p.X), pts.Max(p => p.Y)));
    }

    internal static void AssertInside(Rect r, Size page)
    {
        const double e = 1e-6;
        Assert.True(r.Left >= -e && r.Top >= -e && r.Right <= page.Width + e && r.Bottom <= page.Height + e, r.ToString());
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task AnEditorTurnsBackAndStaysInsideThePageAtEveryRotation(int rotation) => Sta.Run(() =>
    {
        var page = new Size(200, 300);
        foreach (var at in new[] { new Rect(150, 10, 40, 20), new Rect(5, 280, 40, 20), new Rect(100, 150, 40, 20) })
        {
            var overlay = new PageOverlay(0, page);
            TextEditor.Open(overlay, at, 12, "", rotation, _ => { });

            var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
            if (rotation == 0) Assert.Null(box.RenderTransform);
            else Assert.Equal(-rotation, Assert.IsType<RotateTransform>(box.RenderTransform).Angle);
            AssertInside(Footprint(box, box.Width, box.MinHeight), page);
            AssertInside(Footprint(box, box.Width, box.MaxHeight), page);
        }
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task TheCornerAtTheScreenTopLeftStaysWhenTheBoxGrows(int rotation) => Sta.Run(() =>
    {
        var overlay = new PageOverlay(0, new Size(200, 300));
        TextEditor.Open(overlay, new Rect(60, 100, 40, 20), 12, "", rotation, _ => { });
        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Point Corner()
        {
            overlay.InvalidateMeasure();
            box.InvalidateMeasure();
            overlay.Measure(new Size(200, 300));
            overlay.Arrange(new Rect(0, 0, 200, 300));
            return box.TransformToAncestor(overlay).Transform(new Point(0, 0));
        }
        var before = Corner();
        double height = box.ActualHeight;

        box.MinHeight = 90;

        var after = Corner();
        Assert.True(box.ActualHeight > height);
        Assert.Equal(before.X, after.X, 6);
        Assert.Equal(before.Y, after.Y, 6);
        var footprint = PageOverlay.UprightBounds(new Rect(Canvas.GetLeft(box), Canvas.GetTop(box), box.Width, height), rotation);
        var corner = rotation switch
        {
            90 => new Point(footprint.Left, footprint.Bottom),
            180 => new Point(footprint.Right, footprint.Bottom),
            270 => new Point(footprint.Right, footprint.Top),
            _ => new Point(footprint.Left, footprint.Top),
        };
        Assert.Equal(corner.X, before.X, 6);
        Assert.Equal(corner.Y, before.Y, 6);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnEditorReopenedAtAnotherRotationIsTurnedForIt() => Sta.Run(() =>
    {
        var overlay = new PageOverlay(0, new Size(200, 200));
        var editor = TextEditor.Open(overlay, new Rect(10, 10, 100, 20), 12, "", 90, _ => { });
        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        Assert.Equal(-90, Assert.IsType<RotateTransform>(box.RenderTransform).Angle);

        editor.Finish();
        Assert.Empty(overlay.Children);
        TextEditor.Open(overlay, new Rect(10, 10, 100, 20), 12, "", 0, _ => { });

        Assert.Null(Assert.IsType<TextBox>(Assert.Single(overlay.Children)).RenderTransform);
        return Task.CompletedTask;
    });

    private static (InPlaceEditor, TextBox, ViewerStandIn) Unwrapped(int rotation)
    {
        var viewer = ViewerStandIn.Create(out var stand);
        stand.Rotation = rotation;
        var look = new EditorLook(new FontFamily("Arial"), 12, Colors.Black, false, false, LazyPDF.Core.TextAlignment.Left);
        var editor = new InPlaceEditor(viewer);
        editor.Open(0, new Rect(500, 800, 50, 20), "", look, false);
        return (editor, Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children)), stand);
    }

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task AnUnwrappedInPlaceBoxAtATurnedViewStaysInsideThePage(int rotation) => Sta.Run(() =>
    {
        var (_, box, _) = Unwrapped(rotation);

        Assert.False(double.IsPositiveInfinity(box.MaxHeight));
        Assert.Equal(-rotation, Assert.IsType<RotateTransform>(box.RenderTransform).Angle);
        AssertInside(Footprint(box, 50, 20), new Size(595, 842));
        AssertInside(Footprint(box, box.MaxWidth, box.MaxHeight), new Size(595, 842));
        return Task.CompletedTask;
    });

    private static (InPlaceEditor, TextBox, ViewerStandIn) OpenIn(int rotation, Rect area, string text, bool wrap)
    {
        var viewer = ViewerStandIn.Create(out var stand);
        stand.Rotation = rotation;
        var look = new EditorLook(new FontFamily("Arial"), 12, Colors.Black, false, false, LazyPDF.Core.TextAlignment.Left);
        var editor = new InPlaceEditor(viewer);
        editor.Open(0, area, text, look, wrap);
        return (editor, Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children)), stand);
    }

    [Fact]
    public Task AShortRunAtTheTopOfAFlippedViewKeepsAFullLine() => Sta.Run(() =>
    {
        var (_, box, _) = OpenIn(180, new Rect(100, 834, 50, 8), "", false);

        double line = box.FontFamily.LineSpacing * box.FontSize + 2 * box.BorderThickness.Top;
        Assert.True(box.MaxHeight >= line);
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(90, true)]
    [InlineData(180, true)]
    [InlineData(270, true)]
    [InlineData(90, false)]
    [InlineData(180, false)]
    [InlineData(270, false)]
    public Task AnInPlaceBoxTakesItsMaxHeightFromTheRoomLeft(int rotation, bool wrap) => Sta.Run(() =>
    {
        var area = new Rect(500, 800, 50, 20);
        var (_, box, _) = OpenIn(rotation, area, "", wrap);

        var page = new Size(595, 842);
        var room = PageOverlay.Room(PageOverlay.Place(area, page, rotation), page, rotation);
        Assert.Equal(Math.Max(area.Height, room.Height), box.MaxHeight);
        Assert.Equal(Math.Max(area.Width, room.Width), box.MaxWidth);
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task AnInPlaceCaretLandsOnTheSameCharacterAsAtViewZero(int rotation) => Sta.Run(() =>
    {
        var area = new Rect(540, 820, 50, 20);
        var at = new Point(area.X + 22, area.Y + 6);
        int Index(int turn)
        {
            var (_, box, _) = OpenIn(turn, area, "hello world", false);
            box.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            box.Arrange(new Rect(box.DesiredSize));
            return box.GetCharacterIndexFromPoint(InPlaceEditor.InBox(box, at, area), true);
        }

        Assert.Equal(Index(0), Index(rotation));
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task TheInPlaceCornerAtTheScreenTopLeftStaysWhenTheBoxGrows(int rotation) => Sta.Run(() =>
    {
        var (_, box, stand) = OpenIn(rotation, new Rect(300, 400, 50, 20), "", false);
        var overlay = stand.Overlays[0];
        Point Corner()
        {
            overlay.InvalidateMeasure();
            box.InvalidateMeasure();
            overlay.Measure(new Size(overlay.Width, overlay.Height));
            overlay.Arrange(new Rect(0, 0, overlay.Width, overlay.Height));
            return box.TransformToAncestor(overlay).Transform(new Point(0, 0));
        }
        var before = Corner();
        double height = box.ActualHeight;

        box.MinHeight = 90;

        var after = Corner();
        Assert.True(box.ActualHeight > height);
        Assert.Equal(before.X, after.X, 6);
        Assert.Equal(before.Y, after.Y, 6);
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public Task ATextEditorTakesItsMaxHeightFromTheRoomLeft(int rotation) => Sta.Run(() =>
    {
        var page = new Size(200, 300);
        var overlay = new PageOverlay(0, page);
        var area = new Rect(150, 10, 40, 20);
        TextEditor.Open(overlay, area, 12, "", rotation, _ => { });

        var box = Assert.IsType<TextBox>(Assert.Single(overlay.Children));
        var placed = PageOverlay.Place(new Rect(area.X, area.Y, 120, 40), page, rotation);
        Assert.Equal(Math.Max(box.MinHeight, PageOverlay.Room(placed, page, rotation).Height), box.MaxHeight);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnInPlaceBoxAtViewZeroStaysOverTheRun() => Sta.Run(() =>
    {
        var (_, box, _) = Unwrapped(0);

        Assert.Equal(500, Canvas.GetLeft(box));
        Assert.Equal(800, Canvas.GetTop(box));
        Assert.Null(box.RenderTransform);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnInPlaceBoxFollowsAViewTurnAsIfOpenedThere() => Sta.Run(() =>
    {
        var (editor, box, stand) = Unwrapped(90);
        stand.Rotation = 180;

        editor.Upright();

        var (_, fresh, _) = Unwrapped(180);
        Assert.Equal(Canvas.GetLeft(fresh), Canvas.GetLeft(box));
        Assert.Equal(Canvas.GetTop(fresh), Canvas.GetTop(box));
        Assert.Equal(fresh.MaxWidth, box.MaxWidth);
        Assert.Equal(fresh.MaxHeight, box.MaxHeight);
        Assert.Equal(-180, Assert.IsType<RotateTransform>(box.RenderTransform).Angle);

        stand.Rotation = 0;
        editor.Upright();
        Assert.Null(box.RenderTransform);
        Assert.Equal(500, Canvas.GetLeft(box));
        Assert.True(double.IsPositiveInfinity(box.MaxHeight));
        return Task.CompletedTask;
    });

    [Fact]
    public Task RepeatedUprightCallsAtOneRotationChangeNothing() => Sta.Run(() =>
    {
        var (editor, box, _) = Unwrapped(270);
        var transform = box.RenderTransform;
        double left = Canvas.GetLeft(box), maxHeight = box.MaxHeight;

        editor.Upright();
        editor.Upright();

        Assert.Same(transform, box.RenderTransform);
        Assert.Equal(left, Canvas.GetLeft(box));
        Assert.Equal(maxHeight, box.MaxHeight);
        return Task.CompletedTask;
    });
}
