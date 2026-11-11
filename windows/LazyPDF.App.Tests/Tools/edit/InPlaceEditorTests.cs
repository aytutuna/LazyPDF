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
