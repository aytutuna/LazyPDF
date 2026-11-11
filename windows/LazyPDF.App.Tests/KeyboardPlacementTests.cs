using System.Reflection;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.App.Tools.Pages;
using LazyPDF.App.Tools.Redact;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A tool that places something by clicking can be driven from the keyboard: Enter shows a cross in the middle of the
// page in view, the arrow keys move it, Enter again is a click there.
[Collection("Application")]
public sealed class KeyboardPlacementTests
{
    private sealed class RecordingTool : IPagePointerTool
    {
        public List<(string Kind, PagePointer Pointer)> Calls { get; } = [];

        public bool Cancelled { get; private set; }

        public Cursor? Cursor => null;

        public void Press(PagePointer pointer) => Calls.Add(("press", pointer));

        public void Move(PagePointer pointer) => Calls.Add(("move", pointer));

        public void Release(PagePointer pointer) => Calls.Add(("release", pointer));

        public void Cancel() => Cancelled = true;
    }

    private static (PageViewer Viewer, RecordingTool Tool) Open(DocumentTab tab)
    {
        var viewer = new PageViewer();
        viewer.Show(tab);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        var tool = new RecordingTool();
        viewer.PointerTool = tool;
        return (viewer, tool);
    }

    private static DocumentTab NewTab() => new(PdfEditSession.Open(Pdfs.Text(2)), new FakeRenderer(), null, "a.pdf");

    [Fact]
    public Task EnterThenEnterClicksInTheMiddleOfThePageInView() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, tool) = Open(tab);
        var size = viewer.PageSize(0);

        Assert.True(viewer.PlaceWithKeys(Key.Enter));
        Assert.Empty(tool.Calls);
        Assert.True(viewer.PlaceWithKeys(Key.Enter));

        Assert.Equal(["press", "release"], tool.Calls.Select(c => c.Kind));
        var click = tool.Calls[0].Pointer;
        Assert.Equal(0, click.Page);
        Assert.InRange(click.Point.X, 0, size.Width);
        Assert.InRange(click.Point.Y, 0, size.Height);
        Assert.Equal(click.Point, tool.Calls[1].Pointer.Point);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheArrowKeysMoveTheClick() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, tool) = Open(tab);
        viewer.PlaceWithKeys(Key.Enter);
        viewer.PlaceWithKeys(Key.Enter);
        var middle = tool.Calls[0].Pointer.Point;
        tool.Calls.Clear();

        viewer.PlaceWithKeys(Key.Enter);
        viewer.PlaceWithKeys(Key.Right);
        viewer.PlaceWithKeys(Key.Right);
        viewer.PlaceWithKeys(Key.Down);
        viewer.PlaceWithKeys(Key.Enter);

        var moved = tool.Calls[0].Pointer.Point;
        Assert.True(moved.X > middle.X);
        Assert.True(moved.Y > middle.Y);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheCrossStaysInViewWhenZoomedIn() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, tool) = Open(tab);
        viewer.Zoom = 4;
        viewer.UpdateLayout();

        viewer.PlaceWithKeys(Key.Enter);
        for (int i = 0; i < 50; i++) viewer.PlaceWithKeys(Key.Down);
        viewer.UpdateLayout();
        viewer.PlaceWithKeys(Key.Enter);

        var at = tool.Calls[0].Pointer.View;
        Assert.InRange(at.X, 0, 800);
        Assert.InRange(at.Y, 0, 600);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EscapeLetsGoWithoutAClick() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, tool) = Open(tab);
        viewer.PlaceWithKeys(Key.Enter);

        Assert.True(viewer.PlaceWithKeys(Key.Escape));

        Assert.Empty(tool.Calls);
        Assert.False(viewer.PlaceWithKeys(Key.Right));
        return Task.CompletedTask;
    });

    [Fact]
    public Task WithoutAToolTheKeysAreTheViewers() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        viewer.PointerTool = null;

        Assert.False(viewer.PlaceWithKeys(Key.Enter));
        return Task.CompletedTask;
    });

    [Fact]
    public Task EnterThenEnterGivesTheSignatureBoxASize() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        int page = -1;
        Rect box = default;
        viewer.PointerTool = new SignatureBoxTool(viewer, (p, r) => (page, box) = (p, r), () => { });

        viewer.PlaceWithKeys(Key.Enter);
        viewer.PlaceWithKeys(Key.Enter);

        Assert.Equal(0, page);
        Assert.Equal(new Size(180, 60), box.Size);
        Assert.True(new Rect(viewer.PageSize(0)).Contains(box));
        return Task.CompletedTask;
    });

    [Fact]
    public Task EnterThenEnterGivesTheCropBoxASize() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        var crop = new CropTool(viewer);
        viewer.PointerTool = crop;

        viewer.PlaceWithKeys(Key.Enter);
        viewer.PlaceWithKeys(Key.Enter);

        Assert.NotNull(crop.Box);
        Assert.Equal(0, crop.Box!.Value.Page);
        Assert.True(crop.Box.Value.Area.Width > 100);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EnterThenEnterGivesTheRedactBoxASize() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        Point from = default, to = default;
        viewer.PointerTool = new RedactDrawTool(viewer, (_, a, b) => (from, to) = (a, b));

        viewer.PlaceWithKeys(Key.Enter);
        viewer.PlaceWithKeys(Key.Enter);

        Assert.True(to.X - from.X > 50);
        Assert.True(to.Y - from.Y > 10);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AClickWithTheMouseStillMakesNoBox() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        bool drawn = false;
        var tool = new RedactDrawTool(viewer, (_, _, _) => drawn = true);
        var at = new Point(100, 100);

        tool.Press(new PagePointer(0, at, at, true, 1, ModifierKeys.None));
        tool.Release(new PagePointer(0, at, at, false, 0, ModifierKeys.None));

        Assert.False(drawn);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheTiltHookLeavesTheMessageAloneWithoutTheMouseOver() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        var hook = typeof(PageViewer).GetMethod("TiltHook", BindingFlags.Instance | BindingFlags.NonPublic)!;
        object?[] args = [IntPtr.Zero, 0x020E, new IntPtr(120 << 16), IntPtr.Zero, false];

        var result = (IntPtr)hook.Invoke(viewer, args)!;

        Assert.Equal(IntPtr.Zero, result);
        Assert.False((bool)args[4]!);
        return Task.CompletedTask;
    });

    [Fact]
    public Task UnloadingDropsTheHookedSource() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        var field = typeof(PageViewer).GetField("_hooked", BindingFlags.Instance | BindingFlags.NonPublic)!;
        using var source = new HwndSource(new HwndSourceParameters("hook-test"));
        field.SetValue(viewer, source);

        viewer.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));

        Assert.Null(field.GetValue(viewer));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ALeftReleaseDoesNotEndAMiddlePan() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var drag = typeof(PageViewer).GetField("_drag", flags)!;
        var middlePan = typeof(PageViewer).GetField("_middlePan", flags)!;
        var pan = Enum.ToObject(drag.FieldType, 1);
        drag.SetValue(viewer, pan);
        middlePan.SetValue(viewer, true);
        var up = typeof(PageViewer).GetMethod("Surface_MouseUp", flags)!;
        var e = new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = Mouse.MouseUpEvent };

        up.Invoke(viewer, [viewer, e]);

        Assert.True((bool)middlePan.GetValue(viewer)!);
        Assert.Equal(pan, drag.GetValue(viewer));
        Assert.True(e.Handled);
        return Task.CompletedTask;
    });
}
