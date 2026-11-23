using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Comment;

// The two pointer tools of the panel: drawing a new mark, and selecting, moving and resizing one that is there.
public sealed class PointerToolTests
{
    private static readonly MarkStyle Red = MarkStyle.Default with { Color = [0.9, 0.1, 0.1] };

    private static void OnSta(Action test)
    {
        ExceptionDispatchInfo? error = null;
        var thread = new Thread(() =>
        {
            try
            {
                test();
            }
            catch (Exception e)
            {
                error = ExceptionDispatchInfo.Capture(e);
            }
            finally
            {
                Dispatcher.CurrentDispatcher.InvokeShutdown();
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        error?.Throw();
    }

    private static PagePointer Press(Point at, int clicks = 1, int page = 0) => new(page, at, at, true, clicks, ModifierKeys.None);

    private static PagePointer Drag(Point at, int page = 0) => new(page, at, at, true, 0, ModifierKeys.None);

    private static PagePointer Hover(Point at, int page = 0) => new(page, at, at, false, 0, ModifierKeys.None);

    private sealed class Drawn
    {
        public List<(MarkTool Tool, int Page, Point[] Points)> Marks { get; } = [];

        public void Add(MarkTool tool, int page, IReadOnlyList<Point> points) => Marks.Add((tool, page, [.. points]));
    }

    private static DrawTool Drawing(MarkTool tool, out IDocumentViewer viewer, out ViewerStandIn stand, out Drawn drawn)
    {
        viewer = ViewerStandIn.Create(out stand);
        drawn = new Drawn();
        return new DrawTool(viewer, tool, () => Red, drawn.Add);
    }

    [Fact]
    public void ADragDrawsAPreviewAndGivesBothEndsOnRelease()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Rectangle, out _, out var stand, out var drawn);

            tool.Press(Press(new Point(50, 60)));
            tool.Move(Drag(new Point(150, 120)));
            Assert.Single(stand.Overlays[0].Children);
            tool.Release(Drag(new Point(150, 120)));

            Assert.Empty(stand.Overlays[0].Children);
            var made = Assert.Single(drawn.Marks);
            Assert.Equal(MarkTool.Rectangle, made.Tool);
            Assert.Equal([new Point(50, 60), new Point(150, 120)], made.Points);
        });
    }

    [Fact]
    public void ShiftMakesALineStraight()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Line, out _, out _, out var drawn);
            var held = new PagePointer(0, new Point(50, 18), new Point(50, 18), true, 0, ModifierKeys.Shift);

            tool.Press(Press(new Point(10, 10)));
            tool.Move(held);
            tool.Release(held);

            var points = Assert.Single(drawn.Marks).Points;
            Assert.Equal(10, points[1].Y, 6);
        });
    }

    [Fact]
    public void ShiftMakesARectangleASquare()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Rectangle, out _, out _, out var drawn);
            var held = new PagePointer(0, new Point(50, 30), new Point(50, 30), true, 0, ModifierKeys.Shift);

            tool.Press(Press(new Point(10, 10)));
            tool.Release(held);

            Assert.Equal([new Point(10, 10), new Point(50, 50)], Assert.Single(drawn.Marks).Points);
        });
    }

    [Fact]
    public void ShiftOnAStraightDragStillMakesASquare()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Rectangle, out _, out _, out var drawn);

            tool.Press(Press(new Point(10, 10)));
            tool.Release(new PagePointer(0, new Point(60, 10), new Point(60, 10), true, 0, ModifierKeys.Shift));

            Assert.Equal([new Point(10, 10), new Point(60, 60)], Assert.Single(drawn.Marks).Points);
        });
    }

    [Fact]
    public void ShiftNearThePageEdgeShrinksTheWholeSquare()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Rectangle, out _, out _, out var drawn);

            tool.Press(Press(new Point(580, 100)));
            tool.Release(new PagePointer(0, new Point(590, 140), new Point(590, 140), true, 0, ModifierKeys.Shift));

            Assert.Equal([new Point(580, 100), new Point(595, 115)], Assert.Single(drawn.Marks).Points);
        });
    }

    [Fact]
    public void ShiftMakesACalloutLeaderFlat()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Callout, out _, out _, out var drawn);

            tool.Press(Press(new Point(100, 100)));
            tool.Release(new PagePointer(0, new Point(200, 130), new Point(200, 130), true, 0, ModifierKeys.Shift));

            Assert.Equal([new Point(100, 100), new Point(200, 100)], Assert.Single(drawn.Marks).Points);
        });
    }

    [Fact]
    public void WithoutShiftTheEndStaysWhereItIs()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Rectangle, out _, out _, out var drawn);

            tool.Press(Press(new Point(10, 10)));
            tool.Release(Drag(new Point(50, 30)));

            Assert.Equal([new Point(10, 10), new Point(50, 30)], Assert.Single(drawn.Marks).Points);
        });
    }

    [Fact]
    public void AClickWithoutADragDrawsNothingForAShape()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Oval, out _, out var stand, out var drawn);

            tool.Press(Press(new Point(50, 60)));
            tool.Release(Drag(new Point(51, 60)));

            Assert.Empty(drawn.Marks);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }

    [Theory]
    [InlineData(MarkTool.Note)]
    [InlineData(MarkTool.Stamp)]
    [InlineData(MarkTool.Attach)]
    public void AClickToolFinishesOnRelease(MarkTool kind)
    {
        OnSta(() =>
        {
            var tool = Drawing(kind, out _, out _, out var drawn);

            tool.Press(Press(new Point(70, 80)));
            Assert.Empty(drawn.Marks);
            tool.Release(Drag(new Point(70, 80)));

            Assert.Equal([new Point(70, 80)], Assert.Single(drawn.Marks).Points);
        });
    }

    [Fact]
    public void APolygonTakesOneCornerPerClickAndEndsOnADoubleClick()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Polygon, out _, out var stand, out var drawn);

            tool.Press(Press(new Point(10, 10)));
            tool.Release(Drag(new Point(10, 10)));
            tool.Move(Hover(new Point(100, 10)));
            tool.Press(Press(new Point(100, 10)));
            tool.Release(Drag(new Point(100, 10)));
            tool.Press(Press(new Point(100, 100)));
            tool.Release(Drag(new Point(100, 100)));
            Assert.Empty(drawn.Marks);
            Assert.Single(stand.Overlays[0].Children);
            tool.Press(Press(new Point(100, 100), clicks: 2));

            var made = Assert.Single(drawn.Marks);
            Assert.Equal([new Point(10, 10), new Point(100, 10), new Point(100, 100)], made.Points);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }

    private static PagePointer Keyed(Point at, int page = 0) => new(page, at, at, true, 1, ModifierKeys.None, true);

    [Theory]
    [InlineData(MarkTool.Line)]
    [InlineData(MarkTool.Rectangle)]
    public void TwoKeyedClicksDrawADragMark(MarkTool kind)
    {
        OnSta(() =>
        {
            var tool = Drawing(kind, out _, out _, out var drawn);

            tool.Press(Keyed(new Point(20, 30)));
            tool.Release(Keyed(new Point(20, 30)));
            Assert.Empty(drawn.Marks);
            Assert.True(tool.Started);
            tool.Press(Keyed(new Point(120, 90)));
            tool.Release(Keyed(new Point(120, 90)));

            var made = Assert.Single(drawn.Marks);
            Assert.Equal([new Point(20, 30), new Point(120, 90)], made.Points);
            Assert.False(tool.Started);
        });
    }

    [Fact]
    public void AKeyedStartIsDroppedByCancelAndRestartedOnAnotherPage()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Line, out _, out _, out var drawn);

            tool.Press(Keyed(new Point(20, 30)));
            tool.Release(Keyed(new Point(20, 30)));
            tool.Cancel();
            tool.Press(Keyed(new Point(120, 90)));
            tool.Release(Keyed(new Point(120, 90)));
            Assert.Empty(drawn.Marks);

            tool.Press(Keyed(new Point(5, 5), page: 1));
            tool.Release(Keyed(new Point(5, 5), page: 1));
            tool.Press(Keyed(new Point(50, 50), page: 1));
            tool.Release(Keyed(new Point(50, 50), page: 1));
            Assert.Equal(1, Assert.Single(drawn.Marks).Page);
        });
    }

    [Fact]
    public void KeyedPolygonCornersAreFinishedByFinish()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Polygon, out _, out _, out var drawn);

            foreach (var at in new[] { new Point(10, 10), new Point(100, 10) })
            {
                tool.Press(Keyed(at));
                tool.Release(Keyed(at));
            }
            tool.Finish();
            Assert.Empty(drawn.Marks);
            tool.Press(Keyed(new Point(100, 100)));
            tool.Release(Keyed(new Point(100, 100)));
            tool.Finish();

            var made = Assert.Single(drawn.Marks);
            Assert.Equal([new Point(10, 10), new Point(100, 10), new Point(100, 100)], made.Points);
        });
    }

    [Fact]
    public void APolygonClosesWhenTheFirstCornerIsClickedAgain()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Cloud, out _, out _, out var drawn);
            foreach (var corner in new[] { new Point(10, 10), new Point(100, 10), new Point(100, 100) })
            {
                tool.Press(Press(corner));
                tool.Release(Drag(corner));
            }

            tool.Press(Press(new Point(12, 11)));

            Assert.Equal(3, Assert.Single(drawn.Marks).Points.Length);
        });
    }

    [Fact]
    public void APolygonOfTwoCornersIsDropped()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Polygon, out _, out var stand, out var drawn);
            tool.Press(Press(new Point(10, 10)));
            tool.Release(Drag(new Point(10, 10)));
            tool.Press(Press(new Point(100, 10)));
            tool.Release(Drag(new Point(100, 10)));

            tool.Press(Press(new Point(100, 10), clicks: 2));

            Assert.Empty(drawn.Marks);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }

    [Fact]
    public void FreehandKeepsEveryPointOfTheDrag()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Pencil, out _, out _, out var drawn);

            tool.Press(Press(new Point(10, 10)));
            tool.Move(Drag(new Point(20, 14)));
            tool.Move(Drag(new Point(30, 22)));
            tool.Release(Drag(new Point(30, 22)));

            Assert.Equal([new Point(10, 10), new Point(20, 14), new Point(30, 22)], Assert.Single(drawn.Marks).Points);
        });
    }

    [Fact]
    public void ACalloutNeedsADragAndLeavesTwoPreviewShapes()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Callout, out _, out var stand, out var drawn);

            tool.Press(Press(new Point(100, 100)));
            tool.Move(Drag(new Point(300, 200)));
            Assert.Equal(2, stand.Overlays[0].Children.Count);
            tool.Release(Drag(new Point(300, 200)));

            Assert.Equal([new Point(100, 100), new Point(300, 200)], Assert.Single(drawn.Marks).Points);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }

    [Fact]
    public void CancellingDropsWhatWasStarted()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Line, out _, out var stand, out var drawn);
            tool.Press(Press(new Point(10, 10)));
            tool.Move(Drag(new Point(90, 90)));

            tool.Cancel();
            tool.Release(Drag(new Point(90, 90)));

            Assert.Empty(drawn.Marks);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }

    private static EditTool Editing(CommentFixture f, out ViewerStandIn stand, out PdfAnnotation made)
    {
        var viewer = ViewerStandIn.Create(out stand);
        made = f.Marker.Add(MarkTool.TextBox, 0, [new Point(100, 100), new Point(200, 160)], Red, "Look");
        f.Tab.Commit("Text box");
        return new EditTool(viewer, () => f.Marker);
    }

    [Fact]
    public void APressOnAMarkSelectsItAndShowsAFrameWithEightHandles()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out var stand, out var made);
            int raised = 0;
            tool.SelectionChanged += (_, _) => raised++;

            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));

            Assert.Equal(made.Reference!.Number, tool.Current!.Reference!.Number);
            Assert.Equal(9, stand.Overlays[0].Children.Count);
            Assert.Equal(1, raised);
        });
    }

    [Fact]
    public void ALineShowsRoundHandlesAtItsEndsAndMovingOneAsksForThePoint()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out var stand);
            f.Marker.Add(MarkTool.Line, 0, [new Point(100, 100), new Point(300, 200)], Red);
            f.Tab.Commit("Line");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Press(Press(new Point(200, 150)));
            tool.Release(Drag(new Point(200, 150)));
            var moves = new List<(int, Point)>();
            tool.VertexMoved += (_, index, to) => moves.Add((index, to));

            Assert.Equal(3, stand.Overlays[0].Children.Count);
            tool.Press(Press(new Point(300, 200)));
            tool.Move(Drag(new Point(340, 260)));
            tool.Release(Drag(new Point(340, 260)));

            var (index, at) = Assert.Single(moves);
            Assert.Equal(1, index);
            Assert.Equal(new Point(340, 260), at);
        });
    }

    [Theory]
    [InlineData("LL")]
    [InlineData("Measure")]
    public void AFixedMarkHasNoHandlesAndAPressNearAnEndMovesIt(string key)
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out var stand);
            var made = f.Marker.Add(MarkTool.Line, 0, [new Point(100, 100), new Point(300, 200)], Red);
            made.Dictionary[key] = new PdfDictionary();
            f.Tab.Commit("Line");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Select(f.Marks().Single());
            var moves = new List<Vector>();
            int ends = 0;
            tool.Moved += (_, shift) => moves.Add(shift);
            tool.VertexMoved += (_, _, _) => ends++;
            tool.Resized += (_, _) => ends++;

            Assert.Single(stand.Overlays[0].Children);
            Assert.True(tool.Holds(Press(new Point(300, 200))));
            tool.Press(Press(new Point(300, 200)));
            tool.Move(Drag(new Point(320, 230)));
            tool.Release(Drag(new Point(320, 230)));

            Assert.Equal(0, ends);
            var shift = Assert.Single(moves);
            Assert.Equal(20, shift.X, 6);
            Assert.Equal(30, shift.Y, 6);
        });
    }

    [Fact]
    public void ABoxHandleOfAMeasuredShapeDoesNotResizeIt()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out _);
            var made = f.Marker.Add(MarkTool.Rectangle, 0, [new Point(100, 100), new Point(300, 200)], Red);
            made.Dictionary["Measure"] = new PdfDictionary();
            f.Tab.Commit("Rectangle");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Select(f.Marks().Single());
            int resized = 0;
            tool.Resized += (_, _) => resized++;

            tool.Press(Press(new Point(300, 200)));
            tool.Move(Drag(new Point(340, 240)));
            tool.Release(Drag(new Point(340, 240)));

            Assert.Equal(0, resized);
        });
    }

    [Fact]
    public void ACloudShowsRoundHandlesAtItsCorners()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out var stand);
            f.Marker.Add(MarkTool.Cloud, 0, [new Point(100, 100), new Point(300, 100), new Point(300, 300), new Point(100, 300)], Red);
            f.Tab.Commit("Cloud");
            var tool = new EditTool(viewer, () => f.Marker);
            var moves = new List<(int, Point)>();
            tool.VertexMoved += (_, index, to) => moves.Add((index, to));
            tool.Select(f.Marks().Single());

            Assert.Equal(5, stand.Overlays[0].Children.Count);
            tool.Press(Press(new Point(300, 300)));
            tool.Move(Drag(new Point(330, 320)));
            tool.Release(Drag(new Point(330, 320)));

            Assert.Equal((2, new Point(330, 320)), Assert.Single(moves));
        });
    }

    [Fact]
    public void AVertexLeftOverByAnUndoDoesNotBreakTheDragThatFollows()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out _);
            f.Marker.Add(MarkTool.Polygon, 0, [new Point(100, 100), new Point(300, 100), new Point(300, 300), new Point(100, 300)], Red);
            f.Tab.Commit("Polygon");
            var tool = new EditTool(viewer, () => f.Marker);
            var made = f.Marks().Single();
            tool.Select(made);
            int moved = 0;
            tool.VertexMoved += (_, _, _) => moved++;
            tool.Press(Press(new Point(100, 300)));

            made.Dictionary["Vertices"] = new PdfArray([.. new double[] { 100, 742, 300, 742, 300, 542 }.Select(v => (PdfObject)new PdfNumber(v))]);
            tool.Refresh();
            tool.Move(Drag(new Point(120, 320)));
            tool.Release(Drag(new Point(120, 320)));

            Assert.Equal(0, moved);
        });
    }

    private static PagePointer Control(Point at, int clicks = 1) => new(0, at, at, true, clicks, ModifierKeys.Control);

    private static readonly Point[] Corners = [new(100, 100), new(300, 100), new(300, 300), new(100, 300)];

    private static EditTool Polygon(CommentFixture f, MarkTool kind = MarkTool.Polygon)
    {
        var viewer = ViewerStandIn.Create(out _);
        f.Marker.Add(kind, 0, Corners, Red);
        f.Tab.Commit("Shape");
        var tool = new EditTool(viewer, () => f.Marker);
        tool.Select(f.Marks().Single());
        return tool;
    }

    [Fact]
    public void ACtrlPressOnASideAddsACornerThereAndADragPullsItOutInOneStep()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Polygon(f);
            var added = new List<(int, Point)>();
            int moved = 0;
            tool.VertexAdded += (_, after, to) => added.Add((after, to));
            tool.VertexMoved += (_, _, _) => moved++;

            tool.Press(Control(new Point(200, 100)));
            tool.Move(Drag(new Point(230, 60)));
            tool.Move(Drag(new Point(240, 50)));
            tool.Release(Drag(new Point(240, 50)));

            Assert.Equal((0, new Point(240, 50)), Assert.Single(added));
            Assert.Equal(0, moved);
        });
    }

    [Fact]
    public void ARedrawFromAScrollKeepsACornerBeingPulledOut()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Polygon(f);
            var added = new List<(int, Point)>();
            tool.VertexAdded += (_, after, to) => added.Add((after, to));

            tool.Press(Control(new Point(200, 100)));
            tool.Move(Drag(new Point(230, 60)));
            tool.Redraw();
            tool.Move(Drag(new Point(240, 50)));
            tool.Release(Drag(new Point(240, 50)));

            Assert.Equal((0, new Point(240, 50)), Assert.Single(added));
        });
    }

    [Fact]
    public void ACtrlClickOnASideAddsACornerOnTheLine()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Polygon(f);
            var added = new List<(int, Point)>();
            tool.VertexAdded += (_, after, to) => added.Add((after, to));

            tool.Press(Control(new Point(300, 200)));
            tool.Release(Drag(new Point(300, 200)));

            Assert.Equal((1, new Point(300, 200)), Assert.Single(added));
        });
    }

    [Fact]
    public void ACtrlDoubleClickAddsOneCornerAndNeverOpensTheTextEditor()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Polygon(f);
            int added = 0, edits = 0;
            tool.VertexAdded += (mark, after, to) =>
            {
                added++;
                f.Marker.InsertPoint(mark, after, to);
                tool.Refresh();
            };
            tool.EditRequested += _ => edits++;

            tool.Press(Control(new Point(200, 100)));
            tool.Release(Drag(new Point(200, 100)));
            tool.Press(Control(new Point(200, 100), clicks: 2));
            tool.Release(Drag(new Point(200, 100)));

            Assert.Equal(1, added);
            Assert.Equal(0, edits);
        });
    }

    [Fact]
    public void ACtrlPressOnACloudOrALineAddsNothing()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var cloud = Polygon(f, kind: MarkTool.Cloud);
            int added = 0, moved = 0;
            cloud.VertexAdded += (_, _, _) => added++;
            cloud.Moved += (_, _) => moved++;

            cloud.Press(Control(new Point(300, 200)));
            cloud.Move(Drag(new Point(320, 200)));
            cloud.Release(Drag(new Point(320, 200)));

            Assert.Equal(0, added);
            Assert.Equal(1, moved);
        });
    }

    [Fact]
    public void OnAVeryShortLineAPressGoesToTheNearerEndOrMovesTheMark()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out _);
            f.Marker.Add(MarkTool.Line, 0, [new Point(100, 100), new Point(104, 100)], Red);
            f.Tab.Commit("Line");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Select(f.Marks().Single());
            var ends = new List<int>();
            int moved = 0;
            tool.VertexMoved += (_, index, _) => ends.Add(index);
            tool.Moved += (_, _) => moved++;

            tool.Press(Press(new Point(103, 100)));
            tool.Move(Drag(new Point(120, 140)));
            tool.Release(Drag(new Point(120, 140)));
            tool.Refresh();
            tool.Press(Press(new Point(102, 101.5)));
            tool.Move(Drag(new Point(130, 150)));
            tool.Release(Drag(new Point(130, 150)));

            Assert.Equal([1], ends);
            Assert.Equal(1, moved);
        });
    }

    private static PagePointer Held(Point at, ModifierKeys modifiers = ModifierKeys.Shift, bool keys = false) => new(0, at, at, true, 0, modifiers, keys);

    [Fact]
    public void ShiftStraightensAnEndOfALineAgainstTheOtherEndWhileItIsDragged()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out _);
            f.Marker.Add(MarkTool.Line, 0, [new Point(100, 100), new Point(300, 200)], Red);
            f.Tab.Commit("Line");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Select(f.Marks().Single());
            var moves = new List<(int, Point)>();
            tool.VertexMoved += (_, index, to) => moves.Add((index, to));

            tool.Press(Press(new Point(300, 200)));
            tool.Move(Held(new Point(340, 108)));
            tool.Release(Held(new Point(340, 108)));

            var (index, at) = Assert.Single(moves);
            Assert.Equal(1, index);
            Assert.Equal(100, at.Y, 6);
            Assert.Equal(100 + new Vector(240, 8).Length, at.X, 6);
        });
    }

    [Fact]
    public void ShiftStraightensACornerAgainstThePreviousOneAndTheFirstAgainstTheLast()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out _);
            f.Marker.Add(MarkTool.Polygon, 0, [new Point(100, 100), new Point(300, 100), new Point(300, 300), new Point(100, 300)], Red);
            f.Tab.Commit("Polygon");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Select(f.Marks().Single());
            var moves = new List<(int, Point)>();
            tool.VertexMoved += (_, index, to) => moves.Add((index, to));

            tool.Press(Press(new Point(300, 300)));
            tool.Move(Held(new Point(306, 360)));
            tool.Release(Held(new Point(306, 360)));
            tool.Press(Press(new Point(100, 100)));
            tool.Move(Held(new Point(106, 40)));
            tool.Release(Held(new Point(106, 40)));

            Assert.Equal(300, moves[0].Item2.X, 6);
            Assert.Equal(2, moves[0].Item1);
            Assert.Equal(100, moves[1].Item2.X, 3);
            Assert.Equal(0, moves[1].Item1);
        });
    }

    [Fact]
    public void WithoutShiftOrWithKeysAVertexFollowsThePointerExactly()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var viewer = ViewerStandIn.Create(out _);
            f.Marker.Add(MarkTool.Line, 0, [new Point(100, 100), new Point(300, 200)], Red);
            f.Tab.Commit("Line");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Select(f.Marks().Single());
            var moves = new List<Point>();
            tool.VertexMoved += (mark, index, to) =>
            {
                moves.Add(to);
                f.Marker.MovePoint(mark, index, to);
            };

            tool.Press(Press(new Point(300, 200)));
            tool.Move(Held(new Point(340, 108), ModifierKeys.None));
            tool.Release(Held(new Point(340, 108), ModifierKeys.None));
            tool.Refresh();
            tool.Press(Press(new Point(340, 108)));
            tool.Move(Held(new Point(350, 118), ModifierKeys.Shift, keys: true));
            tool.Release(Held(new Point(350, 118), ModifierKeys.Shift, keys: true));

            Assert.Equal(new Point(340, 108), moves[0]);
            Assert.Equal(new Point(350, 118), moves[1]);
        });
    }

    [Fact]
    public void RedrawingAfterTheMarksPageWentAwayDrawsNothing()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture(pages: 2);
            var viewer = ViewerStandIn.Create(out var stand);
            f.Marker.Add(MarkTool.TextBox, 1, [new Point(100, 100), new Point(200, 160)], Red, "Look");
            f.Tab.Commit("Text box");
            var tool = new EditTool(viewer, () => f.Marker);
            tool.Select(f.Marks(1).Single());
            PageOperations.Delete(f.Document, [1]);
            f.Tab.Commit("Delete pages");

            tool.Redraw();

            Assert.Empty(stand.Overlays.Values.SelectMany(o => o.Children.Cast<object>()));
        });
    }

    [Fact]
    public void APressOnNothingLetsGoOfTheSelection()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out var stand, out _);
            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));

            tool.Press(Press(new Point(400, 400)));

            Assert.Null(tool.Current);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }

    [Fact]
    public void DraggingAMarkAsksForTheMoveOnlyOnRelease()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out var stand, out _);
            var moves = new List<Vector>();
            tool.Moved += (_, shift) => moves.Add(shift);

            tool.Press(Press(new Point(150, 130)));
            tool.Move(Drag(new Point(170, 150)));
            Assert.Empty(moves);
            tool.Release(Drag(new Point(170, 150)));

            Assert.Equal(new Vector(20, 20), Assert.Single(moves));
        });
    }

    [Fact]
    public void AClickWithoutMovingAsksForNothing()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out _, out _);
            int asked = 0;
            tool.Moved += (_, _) => asked++;
            tool.Resized += (_, _) => asked++;

            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));

            Assert.Equal(0, asked);
        });
    }

    [Fact]
    public void DraggingACornerHandleAsksForTheNewBox()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out _, out _);
            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));
            var boxes = new List<Rect>();
            tool.Resized += (_, box) => boxes.Add(box);

            tool.Press(Press(new Point(200, 160)));
            tool.Move(Drag(new Point(260, 200)));
            tool.Release(Drag(new Point(260, 200)));

            Assert.Equal(new Rect(100, 100, 160, 100), Assert.Single(boxes));
        });
    }

    [Fact]
    public void AMarkCannotBeResizedBelowASmallestSize()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out _, out _);
            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));
            var boxes = new List<Rect>();
            tool.Resized += (_, box) => boxes.Add(box);

            tool.Press(Press(new Point(200, 160)));
            tool.Move(Drag(new Point(20, 20)));
            tool.Release(Drag(new Point(20, 20)));

            var box = Assert.Single(boxes);
            Assert.Equal(8, box.Width);
            Assert.Equal(8, box.Height);
        });
    }

    [Fact]
    public void ADoubleClickAsksToEditTheText()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out _, out var made);
            PdfAnnotation? asked = null;
            tool.EditRequested += mark => asked = mark;

            tool.Press(Press(new Point(150, 130), clicks: 2));

            Assert.Equal(made.Reference!.Number, asked!.Reference!.Number);
        });
    }

    [Fact]
    public void AMarkThatWasDeletedIsLetGoOfWhenTheFileChanges()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out var stand, out var made);
            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));
            int raised = 0;
            tool.SelectionChanged += (_, _) => raised++;

            f.Marker.Delete(f.Marker.Find(0, made.Reference!.Number)!);
            f.Tab.Commit("Delete");
            tool.Refresh();

            Assert.Null(tool.Current);
            Assert.Equal(1, raised);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }

    [Fact]
    public void ZoomingKeepsTheHandlesTheSameSizeOnScreen()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out var stand, out _);
            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));
            var handle = (System.Windows.Shapes.Rectangle)stand.Overlays[0].Children[1];
            double atFull = handle.Width;

            stand.Zoom = 2;
            tool.Redraw();

            var after = (System.Windows.Shapes.Rectangle)stand.Overlays[0].Children[1];
            Assert.Equal(atFull / 2, after.Width, 0.01);
        });
    }

    [Fact]
    public void AMarkCannotBeDraggedOffThePage()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out _, out _);
            var moves = new List<Vector>();
            tool.Moved += (_, shift) => moves.Add(shift);

            tool.Press(Press(new Point(150, 130)));
            tool.Move(Drag(new Point(2000, -500)));
            tool.Release(Drag(new Point(2000, -500)));

            var shift = Assert.Single(moves);
            Assert.Equal(595 - 200, shift.X, 0.01);
            Assert.Equal(-100, shift.Y, 0.01);
        });
    }

    [Fact]
    public void AMarkCannotBeResizedPastThePage()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out _, out _);
            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));
            var boxes = new List<Rect>();
            tool.Resized += (_, box) => boxes.Add(box);

            tool.Press(Press(new Point(200, 160)));
            tool.Move(Drag(new Point(900, 1200)));
            tool.Release(Drag(new Point(900, 1200)));

            Assert.Equal(new Rect(100, 100, 495, 742), Assert.Single(boxes));
        });
    }

    [Fact]
    public void AMarkTheFileLocksIsNotSelected()
    {
        OnSta(() =>
        {
            using var f = new CommentFixture();
            var tool = Editing(f, out _, out _);
            f.Marks()[0].Dictionary["F"] = new PdfNumber((int)(AnnotationFlags.Print | AnnotationFlags.Locked));

            tool.Press(Press(new Point(150, 130)));
            tool.Release(Drag(new Point(150, 130)));

            Assert.Null(tool.Current);
        });
    }

    [Fact]
    public void ADrawnPolygonKnowsItHasStartedUntilItIsCancelled()
    {
        OnSta(() =>
        {
            var tool = Drawing(MarkTool.Polygon, out _, out var stand, out _);
            Assert.False(tool.Started);

            tool.Press(Press(new Point(10, 10)));
            tool.Release(Drag(new Point(10, 10)));
            Assert.True(tool.Started);

            tool.Cancel();
            Assert.False(tool.Started);
            Assert.Empty(stand.Overlays[0].Children);
        });
    }
}
