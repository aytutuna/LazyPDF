using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Comment;

// Picking an end or corner with Enter, moving it with the arrow keys, adding a corner on a side and removing the picked one.
[Collection("Application")]
public sealed class KeyedPointTests
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    private static readonly Point[] Corners = [new(50, 50), new(150, 50), new(150, 150), new(50, 150)];

    private sealed class Session : IDisposable
    {
        public required DocumentTab Tab { get; init; }
        public required PageViewer Viewer { get; init; }
        public required CommentPanel Panel { get; init; }
        public required RecordingHost Host { get; init; }
        public required EditTool Edit { get; init; }
        public required PdfAnnotation Mark { get; init; }

        public Marker Marker => new(Tab.Document, new FakeFonts(), "Ana", DateTimeOffset.Now);

        public PdfAnnotation Now => Marker.Find(0, Mark.Reference!.Number)!;

        public void Dispose() => Tab.Dispose();
    }

    private static T Get<T>(object owner, string field) => (T)owner.GetType().GetField(field, Private)!.GetValue(owner)!;

    private static Session Start(MarkTool kind = MarkTool.Polygon, Point[]? points = null, MarkTool tool = MarkTool.Edit)
    {
        var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text()), new FakeRenderer(), null, "a.pdf");
        var viewer = new PageViewer(null);
        viewer.Show(tab);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        var marker = new Marker(tab.Document, new FakeFonts(), "Ana", DateTimeOffset.Now);
        var made = marker.Add(kind, 0, points ?? Corners, MarkStyle.Default);
        Assert.True(tab.Commit("Shape"));
        var panel = new CommentPanel();
        var host = new RecordingHost();
        panel.Attach(tab, viewer, host);
        Get<Dictionary<MarkTool, RadioButton>>(panel, "_buttons")[tool].IsChecked = true;
        var edit = Get<EditTool>(panel, "_edit");
        // The commit reads the file back into a new document, so the mark is found again in it.
        var mark = new Marker(tab.Document, new FakeFonts(), "Ana", DateTimeOffset.Now).Find(0, made.Reference!.Number)!;
        edit.Select(mark);
        return new Session { Tab = tab, Viewer = viewer, Panel = panel, Host = host, Edit = edit, Mark = mark };
    }

    // What the viewer sends the tool when Enter is pressed with the cross at a point.
    private static void Enter(IPagePointerTool tool, Point at, ModifierKeys modifiers = ModifierKeys.None)
    {
        tool.Press(new PagePointer(0, at, at, true, 1, modifiers, true));
        tool.Release(new PagePointer(0, at, at, false, 0, modifiers, true));
    }

    private static Point Cross(PageViewer viewer) => (Point)typeof(PageViewer).GetField("_keyPoint", Private)!.GetValue(viewer)!;

    private static int CrossPage(PageViewer viewer) => (int)typeof(PageViewer).GetField("_keyPage", Private)!.GetValue(viewer)!;

    private static bool PressDelete(Session s)
    {
        using var source = new HwndSource(new HwndSourceParameters("delete-test"));
        var args = new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Delete) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
        typeof(CommentPanel).GetMethod("View_PreviewKeyDown", Private)!.Invoke(s.Panel, [s.Viewer, args]);
        return args.Handled;
    }

    [Fact]
    public Task AnEnterOnACornerPicksItAndReopensTheCrossThere() => Sta.Run(() =>
    {
        using var s = Start();

        Enter(s.Edit, new Point(150, 50));

        Assert.Equal(1, s.Edit.PickedVertex);
        Assert.Equal(0, CrossPage(s.Viewer));
        Assert.Equal(s.Marker.PointsOf(s.Now)![1].X, Cross(s.Viewer).X, 0.001);
        Assert.Equal(s.Marker.PointsOf(s.Now)![1].Y, Cross(s.Viewer).Y, 0.001);
        Assert.Equal("Point 2 picked", s.Host.Status);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheArrowKeysMoveThePickedCornerAndTheNextEnterIsOneUndoStep() => Sta.Run(() =>
    {
        using var s = Start();
        Enter(s.Edit, new Point(150, 50));

        s.Viewer.PlaceWithKeys(Key.Right);
        s.Viewer.PlaceWithKeys(Key.Right);
        s.Viewer.PlaceWithKeys(Key.Down);
        Assert.True(s.Viewer.PlaceWithKeys(Key.Enter));

        var moved = s.Marker.PointsOf(s.Now)!;
        Assert.True(moved[1].X > 150);
        Assert.True(moved[1].Y > 50);
        Assert.Equal(50, moved[0].X, 0.5);
        Assert.Equal(-1, s.Edit.PickedVertex);
        Assert.Equal(-1, CrossPage(s.Viewer));
        Assert.Equal("Point 2 moved", s.Host.Status);
        Assert.True(s.Tab.Undo());
        Assert.Equal(150, s.Marker.PointsOf(s.Now)![1].X, 0.5);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EscapeClosesTheCrossAndDropsThePickButKeepsTheSelection() => Sta.Run(() =>
    {
        using var s = Start();
        Enter(s.Edit, new Point(150, 50));

        Assert.True(s.Viewer.PlaceWithKeys(Key.Escape));

        Assert.Equal(-1, s.Edit.PickedVertex);
        Assert.Equal(-1, CrossPage(s.Viewer));
        Assert.NotNull(s.Edit.Current);
        Assert.Equal(8, s.Now.Vertices.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnUndoAfterAPickClearsItAndRaisesNothing() => Sta.Run(() =>
    {
        using var s = Start();
        s.Marker.MovePoint(s.Now, 0, new Point(40, 40));
        Assert.True(s.Tab.Commit("Move point"));
        Enter(s.Edit, new Point(150, 50));
        Assert.Equal(1, s.Edit.PickedVertex);

        Assert.True(s.Tab.Undo());

        Assert.Equal(-1, s.Edit.PickedVertex);
        Assert.Equal(-1, CrossPage(s.Viewer));
        Assert.NotNull(s.Edit.Current);
        return Task.CompletedTask;
    });

    [Fact]
    public Task DeleteRemovesThePickedCornerAndOtherwiseTheMark() => Sta.Run(() =>
    {
        using var s = Start();
        Enter(s.Edit, new Point(150, 50));

        Assert.True(PressDelete(s));

        Assert.Equal(6, s.Now.Vertices.Count);
        Assert.Equal(-1, s.Edit.PickedVertex);
        Assert.Equal(-1, CrossPage(s.Viewer));
        Assert.True(s.Tab.Undo());
        Assert.Equal(8, s.Now.Vertices.Count);

        Assert.True(PressDelete(s));
        Assert.Empty(PdfAnnotations.Read(s.Tab.Document, s.Tab.Document.Pages[0]));
        return Task.CompletedTask;
    });

    [Fact]
    public Task DeleteOnAPickedCornerOfATriangleChangesNothingAndSaysSo() => Sta.Run(() =>
    {
        using var s = Start(points: [new Point(50, 50), new Point(150, 50), new Point(100, 150)]);
        Enter(s.Edit, new Point(150, 50));

        Assert.True(PressDelete(s));

        Assert.Equal(6, s.Now.Vertices.Count);
        Assert.Equal("That point cannot be removed.", s.Host.Status);
        Assert.Equal(-1, s.Edit.PickedVertex);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnEnterOnASideOfAPolygonAddsACornerThere() => Sta.Run(() =>
    {
        using var s = Start();

        Enter(s.Edit, new Point(100, 50));

        var corners = s.Marker.PointsOf(s.Now)!;
        Assert.Equal(5, corners.Length);
        Assert.Equal(100, corners[1].X, 0.5);
        Assert.Equal(50, corners[1].Y, 0.5);
        Assert.True(s.Tab.Undo());
        Assert.Equal(8, s.Now.Vertices.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnEnterOnTheEndOfALinePicksItToo() => Sta.Run(() =>
    {
        using var s = Start(MarkTool.Line, [new Point(40, 60), new Point(160, 120)]);

        Enter(s.Edit, new Point(160, 120));
        s.Viewer.PlaceWithKeys(Key.Left);
        s.Viewer.PlaceWithKeys(Key.Enter);

        var ends = s.Marker.PointsOf(s.Now)!;
        Assert.Equal(40, ends[0].X, 0.5);
        Assert.True(ends[1].X < 160);
        return Task.CompletedTask;
    });

    [Fact]
    public Task WithAnotherToolActiveAKeyedPressOnACornerDrawsInsteadOfPicking() => Sta.Run(() =>
    {
        using var s = Start(tool: MarkTool.Polygon);
        s.Edit.Select(s.Mark);
        var drawing = Get<IPagePointerTool>(s.Panel, "_active");

        Enter(drawing, new Point(150, 50));

        Assert.True(Assert.IsType<DrawTool>(drawing).Started);
        Assert.Equal(-1, s.Edit.PickedVertex);
        Assert.Equal(8, s.Now.Vertices.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AKeyedPlacementWithShiftHeldDoesNotSnapALine() => Sta.Run(() =>
    {
        var viewer = ViewerStandIn.Create(out _);
        var drawn = new List<Point[]>();
        var line = new DrawTool(viewer, MarkTool.Line, () => MarkStyle.Default, (_, _, points) => drawn.Add([.. points]));

        Enter(line, new Point(10, 10));
        Enter(line, new Point(60, 18), ModifierKeys.Shift);

        Assert.Equal(18, Assert.Single(drawn)[1].Y, 6);
        return Task.CompletedTask;
    });
}
