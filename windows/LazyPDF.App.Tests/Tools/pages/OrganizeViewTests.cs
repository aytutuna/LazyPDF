using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The organize view as the window drives it: built on a hidden message-only window, with the drag and drop handlers fed real event arguments.
[Collection("Application")]
public sealed class OrganizeViewTests
{
    private static DocumentTab Open(int pages = 6) =>
        new(PdfEditSession.Open(Pdfs.Text(pages)), new FakeRenderer(), null, "a.pdf");

    private static string TextOf(DocumentTab tab, int page) =>
        System.Text.Encoding.Latin1.GetString(tab.Document.Pages[page].Contents());

    private static string Hex(string text) => Convert.ToHexString(System.Text.Encoding.Latin1.GetBytes(text));

    private static List<string> Order(DocumentTab tab) => [.. Enumerable.Range(0, tab.PageCount).Select(i => TextOf(tab, i))];

    private sealed class StageHost : IToolHost
    {
        public UIElement? Stage { get; private set; }
        public List<Problem> Problems { get; } = [];
        public List<string> Opened { get; } = [];
        public string Status { get; private set; } = "";

        public Task RunBusyAsync(string text, Func<CancellationToken, Task> work) => work(CancellationToken.None);

        public void HoldStage(UIElement? view) => Stage = view;

        public void ShowProblem(Problem problem) => Problems.Add(problem);

        public List<string> Notices { get; } = [];

        public void ShowNotice(string title, string text, NoticeAction? action = null) => Notices.Add(title);

        public void SetStatus(string sentence) => Status = sentence;

        public Task OpenAsync(string path) => Task.CompletedTask;

        public Task<bool> OpenNewAsync(byte[] pdf, string title)
        {
            Opened.Add(title);
            return Task.FromResult(true);
        }

        public Task ReloadAsync(DocumentTab tab) => Task.CompletedTask;
    }

    private sealed class Shown : IDisposable
    {
        private readonly HwndSource _source;

        public Shown(DocumentTab tab, StageHost host)
        {
            View = new OrganizeView();
            var (viewer, _) = FakeViewer.Create();
            View.Attach(tab, viewer, host);
            _source = new HwndSource(new HwndSourceParameters("organize-test") { ParentWindow = new IntPtr(-3), Width = 900, Height = 600 }) { RootVisual = View };
            Layout();
        }

        public OrganizeView View { get; }

        public ListBox Grid => (ListBox)View.FindName("Thumbs");

        public Slider Slider => (Slider)View.FindName("TileSize");

        public List<PageCell> Cells => (List<PageCell>)Grid.ItemsSource;

        public Button Button(string name) => (Button)View.FindName(name);

        public void Layout()
        {
            View.Measure(new Size(900, 600));
            View.Arrange(new Rect(0, 0, 900, 600));
            View.UpdateLayout();
        }

        public void Select(params int[] pages)
        {
            Grid.SelectedItems.Clear();
            foreach (int page in pages) Grid.SelectedItems.Add(Cells[page]);
        }

        public void Click(string name) => Button(name).RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

        public void Dispose()
        {
            View.Detach();
            _source.Dispose();
        }
    }

    // Drag arguments need a constructor WPF keeps to itself; the point is in the target's own space.
    private static DragEventArgs DragArgs(RoutedEvent routed, IDataObject data, UIElement target, Point at)
    {
        var make = typeof(DragEventArgs).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic).Single();
        var e = (DragEventArgs)make.Invoke([data, DragDropKeyStates.None, DragDropEffects.Move | DragDropEffects.Copy, target, at]);
        e.RoutedEvent = routed;
        e.Source = target;
        return e;
    }

    private static Point CentreOf(Shown shown, int cell, bool rightHalf)
    {
        var tiles = PageDrag.Descendant<TilePanel>(shown.Grid)!;
        int columns = Math.Max(1, (int)(tiles.ActualWidth / tiles.CellWidth));
        double x = cell % columns * tiles.CellWidth + (rightHalf ? tiles.CellWidth * 0.75 : tiles.CellWidth * 0.25);
        double y = cell / columns * tiles.CellHeight + tiles.CellHeight / 2;
        return tiles.TranslatePoint(new Point(x, y), shown.Grid);
    }

    private static DragEventArgs Over(Shown shown, IDataObject data, int cell, bool rightHalf, RoutedEvent routed)
    {
        var at = CentreOf(shown, cell, rightHalf);
        var e = DragArgs(routed, data, shown.Grid, at);
        shown.Grid.RaiseEvent(e);
        return e;
    }

    [Fact]
    public Task TheButtonHoldsTheStageAndDoneGivesItBack() => Sta.Run(() =>
    {
        using var tab = Open();
        var host = new StageHost();
        var panel = new PagesPanel();
        var (viewer, _) = FakeViewer.Create();
        panel.Attach(tab, viewer, host);

        ((Button)panel.FindName("Organize")).RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        var view = Assert.IsType<OrganizeView>(host.Stage);
        view.Press(Key.Escape, ModifierKeys.None);
        Assert.Null(host.Stage);

        ((Button)panel.FindName("Organize")).RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        Assert.NotNull(host.Stage);
        panel.Detach();
        Assert.Null(host.Stage);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EveryPageIsATileAndTheSliderResizesThemAll() => Sta.Run(async () =>
    {
        using var tab = Open(40);
        using var shown = new Shown(tab, new StageHost());
        await Dispatcher.Yield(DispatcherPriority.ContextIdle);
        var tiles = PageDrag.Descendant<TilePanel>(shown.Grid)!;
        double before = shown.Cells[0].Width;
        double cell = tiles.CellWidth;

        shown.Slider.Value = 240;
        shown.Layout();

        Assert.Equal(40, shown.Cells.Count);
        Assert.True(shown.Cells[0].Width > before);
        Assert.True(tiles.CellWidth > cell);
        Assert.True(System.Windows.Media.VisualTreeHelper.GetChildrenCount(tiles) < 40);
    });

    [Fact]
    public Task ControlAndShiftSelectAndCtrlASelectsAll() => Sta.Run(() =>
    {
        using var tab = Open();
        var host = new StageHost();
        using var shown = new Shown(tab, host);

        Assert.True(shown.View.Press(Key.A, ModifierKeys.Control));
        Assert.Equal(6, shown.Grid.SelectedItems.Count);
        Assert.Equal("6 of 6 selected", ((System.Windows.Controls.TextBlock)shown.View.FindName("Summary")).Text);

        shown.Select(1);
        shown.Grid.SelectedItems.Add(shown.Cells[4]);
        Assert.Equal(2, shown.Grid.SelectedItems.Count);
        Assert.False(shown.View.Press(Key.B, ModifierKeys.Control));
        return Task.CompletedTask;
    });

    [Fact]
    public Task DeleteRemovesTheSelectedPagesInOneStepThatUndoBringsBack() => Sta.Run(() =>
    {
        using var tab = Open();
        var was = Order(tab);
        using var shown = new Shown(tab, new StageHost());
        shown.Select(1, 2);

        Assert.True(shown.View.Press(Key.Delete, ModifierKeys.None));

        Assert.Equal([was[0], was[3], was[4], was[5]], Order(tab));
        Assert.Equal(4, shown.Cells.Count);
        tab.Undo();
        Assert.Equal(was, Order(tab));
        Assert.Equal(6, shown.Cells.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EveryPageCannotBeDeleted() => Sta.Run(() =>
    {
        using var tab = Open(3);
        var host = new StageHost();
        using var shown = new Shown(tab, host);

        shown.View.Press(Key.A, ModifierKeys.Control);
        shown.View.Press(Key.Delete, ModifierKeys.None);

        Assert.Equal(3, tab.PageCount);
        Assert.Equal("Cannot delete every page", Assert.Single(host.Problems).Title);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheBarTurnsTheSelectionAndTheHoverBarTurnsOnePage() => Sta.Run(() =>
    {
        using var tab = Open();
        using var shown = new Shown(tab, new StageHost());
        shown.Select(0, 2);

        shown.Click("TurnRight");
        Assert.Equal(90, tab.Document.Pages[0].Rotate);
        Assert.Equal(90, tab.Document.Pages[2].Rotate);
        Assert.Equal(0, tab.Document.Pages[1].Rotate);
        Assert.Equal(2, shown.Grid.SelectedItems.Count);

        shown.Click("TurnLeft");
        Assert.Equal(0, tab.Document.Pages[0].Rotate);

        // The buttons of the bar over a page are in its tile; a click on one turns that page.
        var hover = AllButtons(shown.Grid).First(b => b.DataContext is PageCell { Index: 3 } && (string?)b.Tag == "90");
        hover.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        Assert.Equal(90, tab.Document.Pages[3].Rotate);
        Assert.Equal(0, tab.Document.Pages[2].Rotate);
        return Task.CompletedTask;
    });

    private static IEnumerable<Button> AllButtons(DependencyObject parent)
    {
        for (int i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(parent, i);
            if (child is Button { Tag: string } button) yield return button;
            foreach (var inner in AllButtons(child)) yield return inner;
        }
    }

    [Fact]
    public Task DraggingPagesMarksTheGapAndDropMovesThemAsOneStep() => Sta.Run(() =>
    {
        using var tab = Open();
        var was = Order(tab);
        using var shown = new Shown(tab, new StageHost());
        var data = new DataObject(PageDrag.Format, new[] { 0, 1 });

        var over = Over(shown, data, 4, rightHalf: false, UIElement.DragOverEvent);
        Assert.Equal(DragDropEffects.Move, over.Effects);
        Assert.True(shown.Cells[4].DropBefore);
        Over(shown, data, 4, rightHalf: true, UIElement.DragOverEvent);
        Assert.False(shown.Cells[4].DropBefore);
        Assert.True(shown.Cells[4].DropAfter);

        Over(shown, data, 4, rightHalf: false, UIElement.DragOverEvent);
        Over(shown, data, 4, rightHalf: false, UIElement.DropEvent);

        Assert.Equal([was[2], was[3], was[0], was[1], was[4], was[5]], Order(tab));
        Assert.Equal(new[] { 2, 3 }, shown.Grid.SelectedItems.Cast<PageCell>().Select(c => c.Index).Order());
        Assert.All(shown.Cells, c => Assert.False(c.DropBefore || c.DropAfter));
        tab.Undo();
        Assert.Equal(was, Order(tab));
        return Task.CompletedTask;
    });

    [Fact]
    public Task LeavingTheGridClearsTheMark() => Sta.Run(() =>
    {
        using var tab = Open();
        using var shown = new Shown(tab, new StageHost());
        var data = new DataObject(PageDrag.Format, new[] { 0 });

        Over(shown, data, 2, rightHalf: true, UIElement.DragOverEvent);
        Over(shown, data, 2, rightHalf: true, UIElement.DragLeaveEvent);

        Assert.All(shown.Cells, c => Assert.False(c.DropBefore || c.DropAfter));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ADroppedFileGoesInBetweenThePagesAsOneStep() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string file = dir.File("extra.pdf", Pdfs.Text(2, "Dropped"));
        using var tab = Open(4);
        var was = Order(tab);
        using var shown = new Shown(tab, new StageHost());
        int revision = tab.Revision;
        var data = new DataObject(DataFormats.FileDrop, new[] { file });

        var over = Over(shown, data, 1, rightHalf: true, UIElement.DragOverEvent);
        Assert.Equal(DragDropEffects.Copy, over.Effects);
        Over(shown, data, 1, rightHalf: true, UIElement.DropEvent);
        await Sta.Until(() => tab.Revision > revision);

        Assert.Equal(was[0], TextOf(tab, 0));
        Assert.Equal(was[1], TextOf(tab, 1));
        Assert.Contains(Hex("Dropped"), TextOf(tab, 2));
        Assert.Contains(Hex("Dropped"), TextOf(tab, 3));
        Assert.Equal(was[2], TextOf(tab, 4));
        tab.Undo();
        Assert.Equal(was, Order(tab));
    });

    [Fact]
    public Task SomethingThatIsNotAPdfIsRefused() => Sta.Run(async () =>
    {
        using var tab = Open(2);
        var host = new StageHost();
        using var shown = new Shown(tab, host);

        await shown.View.InsertFilesAsync(["notes.txt"], 1);

        Assert.Equal(2, tab.PageCount);
        Assert.Equal("Not a PDF", Assert.Single(host.Problems).Title);
    });

    [Fact]
    public Task CopyThenPasteMovesPagesBetweenTabs() => Sta.Run(async () =>
    {
        using var from = Open(4);
        using var to = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2, "Other")), new FakeRenderer(), null, "b.pdf");
        var fromOrder = Order(from);
        var toOrder = Order(to);
        using (var source = new Shown(from, new StageHost()))
        {
            source.Select(1, 2);
            PageClipboard.Set([], 0);
            Assert.True(source.View.Press(Key.C, ModifierKeys.Control));
            await Sta.Until(() => PageClipboard.Count == 2);
            Assert.Equal(fromOrder, Order(from));
        }

        using var target = new Shown(to, new StageHost());
        int revision = to.Revision;
        target.Select(0);
        Assert.True(target.Button("Paste").IsEnabled);
        target.View.Press(Key.V, ModifierKeys.Control);
        await Sta.Until(() => to.Revision > revision);

        Assert.Equal(toOrder[0], TextOf(to, 0));
        Assert.Equal(fromOrder[1], TextOf(to, 1));
        Assert.Equal(fromOrder[2], TextOf(to, 2));
        Assert.Equal(toOrder[1], TextOf(to, 3));
        Assert.Equal(new[] { 1, 2 }, target.Grid.SelectedItems.Cast<PageCell>().Select(c => c.Index).Order());
        to.Undo();
        Assert.Equal(toOrder, Order(to));
    });

    [Fact]
    public Task CutTakesThePagesOutAsOneStepAndTheyCanBePastedBack() => Sta.Run(async () =>
    {
        using var tab = Open(5);
        var was = Order(tab);
        using var shown = new Shown(tab, new StageHost());
        shown.Select(1, 2);
        int revision = tab.Revision;

        shown.View.Press(Key.X, ModifierKeys.Control);
        await Sta.Until(() => tab.Revision > revision);
        Assert.Equal([was[0], was[3], was[4]], Order(tab));

        shown.Select(0);
        revision = tab.Revision;
        shown.View.Press(Key.V, ModifierKeys.Control);
        await Sta.Until(() => tab.Revision > revision);
        Assert.Equal(was, Order(tab));

        tab.Undo();
        tab.Undo();
        Assert.Equal(was, Order(tab));
    });

    [Fact]
    public Task APasteWithNothingCopiedDoesNothing() => Sta.Run(() =>
    {
        using var tab = Open(2);
        using var shown = new Shown(tab, new StageHost());
        int revision = tab.Revision;
        PageClipboard.Set([], 0);

        shown.View.Press(Key.V, ModifierKeys.Control);

        Assert.Equal(revision, tab.Revision);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ABlankPageGoesAfterTheSelectionAndDuplicateKeepsBothCopiesSelected() => Sta.Run(async () =>
    {
        using var tab = Open(3);
        var was = Order(tab);
        using var shown = new Shown(tab, new StageHost());
        shown.Select(0);

        shown.Click("Blank");
        Assert.Equal(4, tab.PageCount);
        Assert.Equal(new[] { 1 }, shown.Grid.SelectedItems.Cast<PageCell>().Select(c => c.Index));

        shown.Select(0);
        int revision = tab.Revision;
        shown.Click("Duplicate");
        await Sta.Until(() => tab.Revision > revision);
        Assert.Equal(was[0], TextOf(tab, 0));
        Assert.Equal(was[0], TextOf(tab, 1));
        Assert.Equal(new[] { 0, 1 }, shown.Grid.SelectedItems.Cast<PageCell>().Select(c => c.Index).Order());
    });

    [Fact]
    public Task ExtractOpensANewFileAndLeavesTheDocumentAlone() => Sta.Run(async () =>
    {
        using var tab = Open(4);
        var host = new StageHost();
        using var shown = new Shown(tab, host);
        int revision = tab.Revision;
        shown.Select(1, 3);

        shown.Click("Extract");
        await Sta.Until(() => host.Opened.Count == 1);

        Assert.Equal("a extract.pdf", host.Opened[0]);
        Assert.Equal(revision, tab.Revision);
    });

    [Fact]
    public Task ADocumentThatLimitsCopyingCannotBeCopiedFrom() => Sta.Run(async () =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.Print)), new FakeRenderer(), null, "locked.pdf");
        var host = new StageHost();
        using var shown = new Shown(tab, host);
        shown.Select(0);
        PageClipboard.Set([1], 7);

        shown.Click("Copy");
        await Task.Delay(50);

        Assert.Equal(7, PageClipboard.Count);
        Assert.Equal("File is protected", Assert.Single(host.Problems).Title);
    });

    private static void KeyOn(Shown shown, UIElement target, Key key)
    {
        var source = PresentationSource.FromVisual(shown.View)!;
        target.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
    }

    private static MouseButtonEventArgs Mouse(RoutedEvent routed, UIElement target, int clicks = 1)
    {
        var e = new MouseButtonEventArgs(System.Windows.Input.Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = routed, Source = target };
        typeof(MouseButtonEventArgs).GetProperty(nameof(MouseButtonEventArgs.ClickCount))!.GetSetMethod(true)!.Invoke(e, [clicks]);
        return e;
    }

    [Fact]
    public Task KeysWorkWhileFocusIsOnTheBarAndNotOnTheGrid() => Sta.Run(() =>
    {
        using var tab = Open();
        var was = Order(tab);
        using var shown = new Shown(tab, new StageHost());
        shown.Select(1);
        int closed = 0;
        shown.View.Closed += (_, _) => closed++;

        KeyOn(shown, shown.Button("Copy"), Key.Delete);
        Assert.Equal(5, tab.PageCount);
        KeyOn(shown, shown.Slider, Key.Escape);
        Assert.Equal(1, closed);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AJobThatDisablesTheViewDoesNotLeaveTheKeyboardOutsideIt() => Sta.Run(async () =>
    {
        using var tab = Open();
        using var shown = new Shown(tab, new StageHost());
        shown.Button("Copy").Focus();
        shown.View.IsEnabled = false;
        shown.View.IsEnabled = true;

        await Sta.Until(() => shown.Grid.IsKeyboardFocusWithin);
    });

    [Fact]
    public Task ADoubleClickOnTheHoverBarDoesNotLeaveTheView() => Sta.Run(() =>
    {
        using var tab = Open();
        using var shown = new Shown(tab, new StageHost());
        int closed = 0;
        shown.View.Closed += (_, _) => closed++;
        var hover = AllButtons(shown.Grid).First(b => b.DataContext is PageCell { Index: 1 } && (string?)b.Tag == "90");

        hover.RaiseEvent(Mouse(UIElement.MouseDownEvent, hover, 2));
        Assert.Equal(0, closed);

        var tile = (UIElement)shown.Grid.ItemContainerGenerator.ContainerFromIndex(1);
        tile.RaiseEvent(Mouse(UIElement.MouseDownEvent, tile, 2));
        Assert.Equal(1, closed);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheWhereBoxLetsABlankPageBecomeTheFirstPage() => Sta.Run(() =>
    {
        using var tab = Open(3);
        var was = Order(tab);
        using var shown = new Shown(tab, new StageHost());
        shown.Select(2);
        ((ComboBox)shown.View.FindName("Place")).SelectedIndex = 2;

        shown.Click("Blank");

        Assert.Equal(4, tab.PageCount);
        Assert.Equal(was[0], TextOf(tab, 1));
        Assert.Equal(new[] { 0 }, shown.Grid.SelectedItems.Cast<PageCell>().Select(c => c.Index));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFileDroppedOnTheBarGoesToTheEnd() => Sta.Run(async () =>
    {
        using var dir = new TempDir();
        string file = dir.File("extra.pdf", Pdfs.Text(1, "Dropped"));
        using var tab = Open(2);
        using var shown = new Shown(tab, new StageHost());
        int revision = tab.Revision;
        var data = new DataObject(DataFormats.FileDrop, new[] { file });

        var over = DragArgs(UIElement.DragOverEvent, data, shown.Button("Done"), new Point(1, 1));
        shown.Button("Done").RaiseEvent(over);
        Assert.Equal(DragDropEffects.Copy, over.Effects);
        shown.Button("Done").RaiseEvent(DragArgs(UIElement.DropEvent, data, shown.Button("Done"), new Point(1, 1)));
        await Sta.Until(() => tab.Revision > revision);

        Assert.Equal(3, tab.PageCount);
        Assert.Contains(Hex("Dropped"), TextOf(tab, 2));
    });

    [Fact]
    public Task PressingOnOneOfSeveralSelectedPagesKeepsThemUntilItIsReleased() => Sta.Run(() =>
    {
        using var tab = Open();
        using var shown = new Shown(tab, new StageHost());
        shown.Select(1, 2, 3);
        var tile = (UIElement)shown.Grid.ItemContainerGenerator.ContainerFromIndex(2);

        var down = Mouse(UIElement.PreviewMouseLeftButtonDownEvent, tile);
        shown.Grid.RaiseEvent(down);
        Assert.True(down.Handled);
        Assert.Equal(3, shown.Grid.SelectedItems.Count);

        shown.Grid.RaiseEvent(Mouse(UIElement.PreviewMouseLeftButtonUpEvent, tile));
        Assert.Equal(new[] { 2 }, shown.Grid.SelectedItems.Cast<PageCell>().Select(c => c.Index));
        return Task.CompletedTask;
    });

    [Fact]
    public Task PressingTheHoverBarLeavesTheSelectionAlone() => Sta.Run(() =>
    {
        using var tab = Open();
        using var shown = new Shown(tab, new StageHost());
        shown.Select(1, 2, 3);
        var hover = AllButtons(shown.Grid).First(b => b.DataContext is PageCell { Index: 2 } && (string?)b.Tag == "90");

        var down = Mouse(UIElement.PreviewMouseLeftButtonDownEvent, hover);
        shown.Grid.RaiseEvent(down);
        shown.Grid.RaiseEvent(Mouse(UIElement.PreviewMouseLeftButtonUpEvent, hover));

        Assert.False(down.Handled);
        Assert.Equal(3, shown.Grid.SelectedItems.Count);
        return Task.CompletedTask;
    });

    [Fact]
    public Task CopyingOutOfAnEncryptedFileSaysTheCopyIsNotProtected() => Sta.Run(async () =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Restricted(PdfPermissions.All)), new FakeRenderer(), null, "locked.pdf");
        var host = new StageHost();
        using var shown = new Shown(tab, host);
        shown.Select(0);
        PageClipboard.Set([], 0);

        shown.Click("Copy");
        await Sta.Until(() => PageClipboard.Count == 1);

        Assert.Equal("Copy is not protected", Assert.Single(host.Notices));
    });
}
