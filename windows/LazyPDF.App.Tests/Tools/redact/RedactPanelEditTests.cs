using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Redact;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The review list and the frame on a drawn box have to agree when a pick or a file change comes in the middle of an edit.
[Collection("Application")]
public sealed class RedactPanelEditTests
{
    private static readonly PageGeometry Geometry = new(new PdfRect(0, 0, 200, 300), 0);

    private sealed class Stand : IDisposable
    {
        public DocumentTab Tab = new(PdfEditSession.Open(Pdfs.Text(2), (string?)null), new FakeRenderer(), null, "a.pdf", null);
        public RedactPanel Panel = new();
        public PageOverlay Overlay;
        public HwndSource Source = new(new HwndSourceParameters("redact-edit"));

        public Stand()
        {
            var (viewer, overlay) = FakeViewer.Create();
            Overlay = overlay;
            Panel.Attach(Tab, viewer, new RecordingHost());
        }

        public MarkList Marks
        {
            get
            {
                var state = typeof(RedactPanel).GetField("_state", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(Panel)!;
                return (MarkList)state.GetType().GetProperty("Marks")!.GetValue(state)!;
            }
        }

        public ListBox List => (ListBox)typeof(RedactPanel).GetField("MarkedList", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(Panel)!;

        public FrameworkElement? Frame => Overlay.Children.OfType<FrameworkElement>().FirstOrDefault(e => e.GetType().Name == "Frame");

        public MarkItem Show(string label, double left, double top)
        {
            var item = new MarkItem(MarkShapes.Box(0, Geometry, new Point(left, top), new Point(left + 60, top + 20)), label, IsBox: true);
            Marks.Add([item]);
            return item;
        }

        public MarkItem Select(string label)
        {
            var item = Marks.Items.Single(m => m.Label == label);
            List.SelectedItem = item;
            return item;
        }

        public void Press(Key key)
        {
            var args = new KeyEventArgs(Keyboard.PrimaryDevice, Source, 0, key) { RoutedEvent = Keyboard.KeyDownEvent, Source = Frame };
            Frame!.RaiseEvent(args);
        }

        public void LoseFocus() =>
            Frame!.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice, 0, Frame, Panel) { RoutedEvent = Keyboard.LostKeyboardFocusEvent });

        public Rect Shown(MarkItem item) => MarkShapes.Where(Geometry, item.Mark);

        public void Dispose()
        {
            Source.Dispose();
            Tab.Dispose();
        }
    }

    [Fact]
    public Task APickByCodeMidNudgeKeepsTheNudgeAndFramesTheNewRow() => Sta.Run(() =>
    {
        using var stand = new Stand();
        var a = stand.Show("a", 20, 30);
        var b = stand.Show("b", 20, 100);
        stand.Select("a");
        stand.Press(Key.Right);
        stand.Press(Key.Right);

        stand.List.SelectedItem = b;

        var moved = stand.Marks.Items.Single(m => m.Label == "a");
        Assert.Equal(new Rect(22, 30, 60, 20), stand.Shown(moved));
        Assert.Same(b, stand.List.SelectedItem);
        Assert.Equal(2, stand.Marks.Items.Count);
        Assert.Equal(stand.Shown(b), new Rect(Canvas.GetLeft(stand.Frame!), Canvas.GetTop(stand.Frame!), stand.Frame!.Width, stand.Frame.Height));
        Assert.NotSame(a, moved);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AClickOnAnotherRowAfterTheFrameLostFocusLeavesThatRowPicked() => Sta.Run(() =>
    {
        using var stand = new Stand();
        stand.Show("a", 20, 30);
        var b = stand.Show("b", 20, 100);
        stand.Select("a");
        stand.Press(Key.Down);

        stand.LoseFocus();
        Assert.Equal("a", ((MarkItem)stand.List.SelectedItem).Label);
        stand.List.SelectedItem = b;

        Assert.Same(b, stand.List.SelectedItem);
        Assert.Equal(new Rect(20, 31, 60, 20), stand.Shown(stand.Marks.Items.Single(m => m.Label == "a")));
        Assert.Equal(stand.Shown(b), new Rect(Canvas.GetLeft(stand.Frame!), Canvas.GetTop(stand.Frame!), stand.Frame!.Width, stand.Frame.Height));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ALostFocusAloneKeepsTheEditedRowPickedAndFramed() => Sta.Run(() =>
    {
        using var stand = new Stand();
        stand.Show("a", 20, 30);
        stand.Select("a");
        stand.Press(Key.Right);

        stand.LoseFocus();

        var edited = stand.Marks.Items.Single();
        Assert.Same(edited, stand.List.SelectedItem);
        Assert.Equal(new Rect(21, 30, 60, 20), new Rect(Canvas.GetLeft(stand.Frame!), Canvas.GetTop(stand.Frame!), stand.Frame!.Width, stand.Frame.Height));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ANudgeKeepsTheLabelTheBoxFlagAndWholePageOff() => Sta.Run(() =>
    {
        using var stand = new Stand();
        stand.Show("a", 20, 30);
        stand.Select("a");
        stand.Press(Key.Left);
        stand.LoseFocus();

        var edited = stand.Marks.Items.Single();
        Assert.Equal("a", edited.Label);
        Assert.True(edited.IsBox);
        Assert.False(edited.IsWholePage);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ANudgeJustBeforeApplyIsTheRectThatIsRedacted() => Sta.Run(() =>
    {
        using var stand = new Stand();
        stand.Show("a", 20, 30);
        stand.Select("a");
        stand.Press(Key.Right);

        // Clicking the apply button takes keyboard focus first.
        stand.LoseFocus();

        var rect = stand.Marks.Items.Single().Mark.Quads[0].Bounds;
        Assert.Equal(21, rect.Left, 6);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFileChangeForgetsTheHistoryOfHitsThatWereTakenOut() => Sta.Run(() =>
    {
        using var stand = new Stand();
        var rect = RedactionMark.FromRect(0, new PdfRect(100, 100, 120, 120));
        stand.Marks.Add([new MarkItem(rect, "hit", Value: new RedactionValueMatch(0, 2, RedactionValueSource.Comment, 0, 3, "abc", RedactionKind.Word))]);
        stand.Show("box", 20, 30);

        stand.Tab.Refresh();

        Assert.False(stand.Marks.CanUndo);
        Assert.Equal(["box"], stand.Marks.Items.Select(m => m.Label));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFileChangeForgetsHitsThatWereClearedBeforeIt() => Sta.Run(() =>
    {
        using var stand = new Stand();
        var rect = RedactionMark.FromRect(0, new PdfRect(100, 100, 120, 120));
        stand.Marks.Add([new MarkItem(rect, "hit", Value: new RedactionValueMatch(0, 2, RedactionValueSource.Comment, 0, 3, "abc", RedactionKind.Word))]);
        stand.Marks.Clear();
        Assert.True(stand.Marks.CanUndo);

        stand.Tab.Refresh();

        Assert.False(stand.Marks.CanUndo);
        stand.Marks.Undo();
        Assert.Empty(stand.Marks.Items);
        return Task.CompletedTask;
    });
}
