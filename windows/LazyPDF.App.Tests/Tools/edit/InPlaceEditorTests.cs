using System.Windows.Controls;
using LazyPDF.App.Tests.Tools.Comment;
using LazyPDF.App.Tools.EditContent;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Edit;

[Collection("Application")]
public sealed class InPlaceEditorTests
{
    private static TextBox Opened(bool lineBreaks)
    {
        var viewer = ViewerStandIn.Create(out var stand);
        var look = new EditorLook(new System.Windows.Media.FontFamily("Arial"), 12, System.Windows.Media.Colors.Black, false, false, LazyPDF.Core.TextAlignment.Left);
        new InPlaceEditor(viewer).Open(0, new System.Windows.Rect(10, 10, 100, 20), "", look, wrap: true, lineBreaks: lineBreaks);
        return Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children));
    }

    [Fact]
    public Task ANewBoxAcceptsReturn() => Sta.Run(() => { Assert.True(Opened(true).AcceptsReturn); return Task.CompletedTask; });

    [Fact]
    public Task ALineEditDoesNot() => Sta.Run(() => { Assert.False(Opened(false).AcceptsReturn); return Task.CompletedTask; });

    [Fact]
    public Task CtrlShiftEnterStartsALine() => Sta.Run(() =>
    {
        var viewer = ViewerStandIn.Create(out var stand);
        var look = new EditorLook(new System.Windows.Media.FontFamily("Arial"), 12, System.Windows.Media.Colors.Black, false, false, LazyPDF.Core.TextAlignment.Left);
        var editor = new InPlaceEditor(viewer);
        editor.Open(0, new System.Windows.Rect(10, 10, 100, 20), "ab", look, wrap: true, lineBreaks: true);
        Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children)).CaretIndex = 2;
        bool committed = false;
        editor.Committed += (_, _) => committed = true;
        var args = new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, new System.Windows.Interop.HwndSource(new System.Windows.Interop.HwndSourceParameters()), 0, System.Windows.Input.Key.Enter) { RoutedEvent = System.Windows.Input.Keyboard.PreviewKeyDownEvent };

        editor.PressKey(args, System.Windows.Input.ModifierKeys.Control | System.Windows.Input.ModifierKeys.Shift);

        Assert.Equal("ab" + Environment.NewLine, editor.Text);
        Assert.True(args.Handled);
        Assert.False(committed);
        return Task.CompletedTask;
    });

    private static TextBox OpenedWith(string text, LazyPDF.Core.TextAlignment? alignment)
    {
        var viewer = ViewerStandIn.Create(out var stand);
        var look = new EditorLook(new System.Windows.Media.FontFamily("Arial"), 12, System.Windows.Media.Colors.Black, false, false, alignment);
        new InPlaceEditor(viewer).Open(0, new System.Windows.Rect(10, 10, 100, 20), text, look, wrap: true);
        return Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children));
    }

    [Fact]
    public Task HebrewTextReadsRightToLeftAndKeepsTheRightEdge() => Sta.Run(() =>
    {
        var box = OpenedWith("אבג", LazyPDF.Core.TextAlignment.Right);
        Assert.Equal(System.Windows.FlowDirection.RightToLeft, box.FlowDirection);
        Assert.Equal(System.Windows.TextAlignment.Left, box.TextAlignment);
        return Task.CompletedTask;
    });

    [Fact]
    public Task LatinTextStaysLeftToRight() => Sta.Run(() =>
    {
        var box = OpenedWith("abc", LazyPDF.Core.TextAlignment.Right);
        Assert.Equal(System.Windows.FlowDirection.LeftToRight, box.FlowDirection);
        Assert.Equal(System.Windows.TextAlignment.Right, box.TextAlignment);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TypingHebrewIntoALeftAlignedBoxTurnsItAroundAndKeepsTheLeftEdge() => Sta.Run(() =>
    {
        var box = OpenedWith("abc", LazyPDF.Core.TextAlignment.Left);
        box.Text = "אבג";
        Assert.Equal(System.Windows.FlowDirection.RightToLeft, box.FlowDirection);
        Assert.Equal(System.Windows.TextAlignment.Right, box.TextAlignment);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnAlignmentThatIsNotSetStartsTheLine() => Sta.Run(() =>
    {
        var box = OpenedWith("אבג", null);
        Assert.Equal(System.Windows.TextAlignment.Left, box.TextAlignment);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AClickNearTheLeftOfAHebrewBoxIsMeasuredFromItsRightEdge() => Sta.Run(() =>
    {
        var box = OpenedWith("אבג", null);
        box.Measure(new System.Windows.Size(100, 20));
        box.Arrange(new System.Windows.Rect(0, 0, 100, 20));
        var area = new System.Windows.Rect(10, 10, 100, 20);

        var point = InPlaceEditor.InBox(box, new System.Windows.Point(15, 12), area);

        Assert.Equal(95, point.X);
        Assert.Equal(2, point.Y);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AClickInALatinBoxIsMeasuredFromItsLeftEdge() => Sta.Run(() =>
    {
        var box = OpenedWith("abc", null);
        box.Measure(new System.Windows.Size(100, 20));
        box.Arrange(new System.Windows.Rect(0, 0, 100, 20));

        var point = InPlaceEditor.InBox(box, new System.Windows.Point(15, 12), new System.Windows.Rect(10, 10, 100, 20));

        Assert.Equal(5, point.X);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ARotatedViewTurnsTheBoxBack() => Sta.Run(() =>
    {
        var viewer = ViewerStandIn.Create(out var stand);
        stand.Rotation = 90;
        var look = new EditorLook(new System.Windows.Media.FontFamily("Arial"), 12, System.Windows.Media.Colors.Black, false, false, LazyPDF.Core.TextAlignment.Left);
        var editor = new InPlaceEditor(viewer);
        editor.Open(0, new System.Windows.Rect(10, 10, 100, 20), "", look, wrap: true);

        var box = Assert.IsType<TextBox>(Assert.Single(stand.Overlays[0].Children));
        Assert.Equal(-90, Assert.IsType<System.Windows.Media.RotateTransform>(box.RenderTransform).Angle);
        stand.Rotation = 0;
        editor.Upright();
        Assert.Null(box.RenderTransform);
        return Task.CompletedTask;
    });
}
