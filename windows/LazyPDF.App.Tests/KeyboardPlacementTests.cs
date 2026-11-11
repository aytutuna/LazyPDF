using System.Reflection;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
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
        var viewer = new PageViewer(null);
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

    private static object Call(PageViewer viewer, string name, params object[] args) =>
        typeof(PageViewer).GetMethod(name, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(viewer, args)!;

    [Fact]
    public Task AToastShowsItsTextUntilTheTimerHidesIt() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        var toast = (UIElement)viewer.FindName("Toast");
        var text = (System.Windows.Controls.TextBlock)viewer.FindName("ToastText");

        Call(viewer, "ShowToast", "Copied", 3000);

        Assert.Equal(Visibility.Visible, toast.Visibility);
        Assert.Equal("Copied", text.Text);
        Call(viewer, "HideToast");
        Assert.Equal(Visibility.Collapsed, toast.Visibility);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ReadAloudSaysEachPageInOrderUntilStopped() => Sta.Run(async () =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var (viewer, _) = Open(tab);
        var said = new List<string>();
        var second = new TaskCompletionSource();
        viewer.Say = async (text, cancel) =>
        {
            said.Add(text);
            if (said.Count == 2) second.SetResult();
            if (said.Count >= 2) await Task.Delay(Timeout.Infinite, cancel);
        };

        viewer.ToggleReadAloud();
        await second.Task;
        Assert.True(viewer.Speaking);
        Assert.Contains("Page 1", said[0]);
        Assert.Contains("Page 2", said[1]);
        Assert.Equal(1, viewer.PageIndex);

        Call(viewer, "StopSpeech");
        Assert.False(viewer.Speaking);
    });

    [Fact]
    public Task SwitchingTabsStopsReadAloud() => Sta.Run(async () =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        var started = new TaskCompletionSource<CancellationToken>();
        viewer.Say = async (_, cancel) =>
        {
            started.SetResult(cancel);
            await Task.Delay(Timeout.Infinite, cancel);
        };

        viewer.ToggleReadAloud();
        var token = await started.Task;
        viewer.Show(null);

        Assert.True(token.IsCancellationRequested);
        Assert.False(viewer.Speaking);
    });

    [Fact]
    public Task ReadAloudOfAFileWithNoTextShowsAToast() => Sta.Run(async () =>
    {
        var session = PdfEditSession.Open(Pdfs.Text(1));
        PageOperations.InsertBlank(session.Document, 1, 612, 792, 2);
        PageOperations.Delete(session.Document, [0]);
        session.Commit("Delete");
        using var tab = new DocumentTab(session, new FakeRenderer(), null, "a.pdf");
        var (viewer, _) = Open(tab);
        var said = new List<string>();
        viewer.Say = (text, _) =>
        {
            said.Add(text);
            return Task.CompletedTask;
        };

        viewer.ToggleReadAloud();
        while (viewer.Speaking) await Task.Delay(10);

        Assert.Empty(said);
        Assert.Equal("This file has no text to read. Try Make searchable.", ((System.Windows.Controls.TextBlock)viewer.FindName("ToastText")).Text);
    });

    [Fact]
    public void PiecesSplitOnABlankLine()
    {
        Assert.Equal(["One two", "Three"], PageViewer.Pieces("One\ntwo\r\n\r\n \nThree\n"));
    }

    [Fact]
    public Task SpeakSetsTheHiddenLine() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        var speech = (System.Windows.Controls.TextBlock)viewer.FindName("Speech");

        Call(viewer, "Speak", "Page 2");

        Assert.Equal("Page 2", speech.Text);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ToastAndSpeechDoNothingWithoutAFile() => Sta.Run(() =>
    {
        var viewer = new PageViewer(null);
        viewer.Show(null);

        Call(viewer, "ShowToast", "Copied", 3000);
        Call(viewer, "Speak", "Page 2");

        Assert.Equal(Visibility.Collapsed, ((UIElement)viewer.FindName("Toast")).Visibility);
        Assert.Equal("", ((System.Windows.Controls.TextBlock)viewer.FindName("Speech")).Text);
        return Task.CompletedTask;
    });

    private static MouseButtonEventArgs Click(RoutedEvent routed, int clicks)
    {
        var e = new MouseButtonEventArgs(Mouse.PrimaryDevice, 0, MouseButton.Left) { RoutedEvent = routed };
        typeof(MouseButtonEventArgs).GetProperty(nameof(MouseButtonEventArgs.ClickCount))!.GetSetMethod(true)!.Invoke(e, [clicks]);
        return e;
    }

    private static async Task<bool> DoubleClickThenAsync(Action<PageViewer>? between)
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        viewer.PointerTool = null;
        var down = typeof(PageViewer).GetMethod("Surface_MouseDown", BindingFlags.Instance | BindingFlags.NonPublic)!;
        down.Invoke(viewer, [viewer, Click(Mouse.MouseDownEvent, 2)]);
        between?.Invoke(viewer);
        await viewer.GetTextAsync(0);
        await Task.Delay(200);
        return viewer.HasSelection;
    }

    [Fact]
    public Task ADoubleClickSelectsTheWordOnceThePageTextIsThere() => Sta.Run(async () =>
    {
        Assert.True(await DoubleClickThenAsync(null));
    });

    [Fact]
    public Task AClearedSelectionIsNotRestoredByADoubleClickStillWaitingForText() => Sta.Run(async () =>
    {
        Assert.False(await DoubleClickThenAsync(viewer => viewer.ClearSelection()));
    });

    [Fact]
    public Task SwitchingToTheHandIsNotUndoneByADoubleClickStillWaitingForText() => Sta.Run(async () =>
    {
        Assert.False(await DoubleClickThenAsync(viewer => viewer.Mode = PointerMode.Hand));
    });

    [Fact]
    public Task AQuickThirdPressOnALinkFollowsItAgain() => Sta.Run(() =>
    {
        var document = PdfDocument.Open(Pdfs.Text(3));
        foreach (var page in document.Pages) PdfLinks.Add(document, page, new PdfRect(0, 0, 10000, 10000), new PdfDestination(2));
        using var tab = new DocumentTab(PdfEditSession.Open(document.SaveRewrite()), new FakeRenderer(), null, "a.pdf");
        var (viewer, _) = Open(tab);
        viewer.PointerTool = null;
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var surface = (PageSurface)typeof(PageViewer).GetField("Surface", flags)!.GetValue(viewer)!;
        surface.SetZoom(4);
        // A press lands at the surface's origin, so put a spot inside page 0 there.
        void Back() => surface.GoToPage(0, new Point(100, 100));
        var down = typeof(PageViewer).GetMethod("Surface_MouseDown", flags)!;
        var up = typeof(PageViewer).GetMethod("Surface_MouseUp", flags)!;
        void Press(int clicks)
        {
            down.Invoke(viewer, [viewer, Click(Mouse.MouseDownEvent, clicks)]);
            up.Invoke(viewer, [viewer, Click(Mouse.MouseUpEvent, clicks)]);
        }

        Back();
        Press(1);
        Assert.Equal(2, tab.PageIndex);

        Back();
        Press(2);
        Assert.Equal(0, tab.PageIndex);
        Assert.False(viewer.HasSelection);

        Press(3);
        Assert.Equal(2, tab.PageIndex);
        return Task.CompletedTask;
    });

    private static bool PressKey(PageViewer viewer, Key key)
    {
        using var source = new HwndSource(new HwndSourceParameters("key-test"));
        var args = new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, key) { RoutedEvent = Keyboard.KeyDownEvent };
        typeof(PageViewer).GetMethod("Surface_KeyDown", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(viewer, [viewer, args]);
        return args.Handled;
    }

    [Fact]
    public Task TabWalksTheLinksAndEnterFollowsTheFocusedOne() => Sta.Run(() =>
    {
        var document = PdfDocument.Open(Pdfs.Text(3));
        PdfLinks.Add(document, document.Pages[0], new PdfRect(50, 300, 150, 350), new PdfDestination(1));
        PdfLinks.Add(document, document.Pages[0], new PdfRect(50, 600, 150, 650), new PdfDestination(2));
        using var tab = new DocumentTab(PdfEditSession.Open(document.SaveRewrite()), new FakeRenderer(), null, "a.pdf");
        var (viewer, _) = Open(tab);
        viewer.PointerTool = null;
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var focus = typeof(PageViewer).GetField("_focusLink", flags)!;

        Assert.True(PressKey(viewer, Key.Tab));
        Assert.Equal(new PdfRect(50, 600, 150, 650), ((ValueTuple<int, PdfLink>)focus.GetValue(viewer)!).Item2.Rect);
        Assert.True(PressKey(viewer, Key.Tab));
        Assert.Equal(new PdfRect(50, 300, 150, 350), ((ValueTuple<int, PdfLink>)focus.GetValue(viewer)!).Item2.Rect);
        Assert.True(PressKey(viewer, Key.Enter));
        Assert.Equal(1, tab.PageIndex);

        viewer.GoToPage(0);
        Assert.False(PressKey(viewer, Key.Tab));
        Assert.Null(focus.GetValue(viewer));
        return Task.CompletedTask;
    });

    private static void PressEnterInZoomBox(PageViewer viewer)
    {
        using var source = new HwndSource(new HwndSourceParameters("zoom-test"));
        viewer.ZoomBox.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Enter) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
    }

    [Fact]
    public Task EnterInTheZoomBoxWithUntouchedTextKeepsFitWidth() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        viewer.Fit = FitMode.Width;
        viewer.UpdateLayout();

        PressEnterInZoomBox(viewer);

        Assert.Equal(FitMode.Width, viewer.Fit);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AnUnreadableZoomEntryGoesBackToTheShownValue() => Sta.Run(() =>
    {
        using var tab = NewTab();
        var (viewer, _) = Open(tab);
        string shown = viewer.ZoomBox.Text;
        viewer.ZoomBox.Text = "abc";

        PressEnterInZoomBox(viewer);

        Assert.Equal(shown, viewer.ZoomBox.Text);
        return Task.CompletedTask;
    });

    [Theory]
    [InlineData(360)]
    [InlineData(440)]
    [InlineData(520)]
    public Task TheZoomGroupFitsAtNarrowWidths(int width) => Sta.Run(() =>
    {
        using var tab = NewTab();
        var viewer = new PageViewer(null);
        viewer.Show(tab);
        viewer.Measure(new Size(width, 600));
        viewer.Arrange(new Rect(0, 0, width, 600));
        viewer.UpdateLayout();
        double actual = viewer.ZoomGroup.ActualWidth;
        viewer.ZoomGroup.Measure(new Size(double.PositiveInfinity, 600));

        Assert.Equal(viewer.ZoomGroup.DesiredSize.Width - 16, actual, 1.5);
        return Task.CompletedTask;
    });

    private static void Click(PageViewer viewer, string handler, object item) =>
        typeof(PageViewer).GetMethod(handler, BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(viewer, [item, new RoutedEventArgs()]);

    [Fact]
    public Task TheViewerOpensInTheSavedTintAndLayout() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        AppPreferencesStore.Update(p => { p.Tint = PageTint.Dark; p.Columns = 2; p.Cover = true; p.Continuous = false; }, dir.Path);

        var viewer = new PageViewer(dir.Path);

        Assert.Equal(PageTint.Dark, viewer.Surface.Tint);
        Assert.Equal(2, viewer.Surface.Columns);
        Assert.True(viewer.Surface.Cover);
        Assert.False(viewer.Surface.Continuous);
        return Task.CompletedTask;
    });

    [Fact]
    public Task AViewerWithoutASettingsFolderStartsPlainAndSavesNothing() => Sta.Run(() =>
    {
        var viewer = new PageViewer(null);

        Click(viewer, "Tint_Click", viewer.TintDarkItem);
        Click(viewer, "Arrangement_Click", viewer.TwoPageItem);

        Assert.Equal(PageTint.Dark, viewer.Surface.Tint);
        Assert.Equal(2, viewer.Surface.Columns);
        Assert.Equal(PageTint.None, new PageViewer(null).Surface.Tint);
        Assert.Equal(1, new PageViewer(null).Surface.Columns);
        Assert.True(new PageViewer(null).Surface.Continuous);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheTintAndTheLayoutPickedInTheMenuAreSaved() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        var viewer = new PageViewer(dir.Path);

        Click(viewer, "Tint_Click", viewer.TintSepiaItem);
        Click(viewer, "Arrangement_Click", viewer.TwoPageItem);
        Click(viewer, "Arrangement_Click", viewer.CoverItem);

        var saved = AppPreferencesStore.Load(dir.Path);
        Assert.Equal(PageTint.Sepia, saved.Tint);
        Assert.Equal(2, saved.Columns);
        Assert.True(saved.Cover);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ReadingModesOneColumnLayoutIsNotSaved() => Sta.Run(() =>
    {
        using var dir = new TempDir();
        AppPreferencesStore.Update(p => { p.Columns = 2; p.Continuous = false; }, dir.Path);
        var viewer = new PageViewer(dir.Path);

        viewer.ReadingMode = true;
        Assert.Equal(1, viewer.Surface.Columns);

        var saved = AppPreferencesStore.Load(dir.Path);
        Assert.Equal(2, saved.Columns);
        Assert.False(saved.Continuous);
        return Task.CompletedTask;
    });

    [Fact]
    public Task OnePageFromTwoPagesContinuousStaysContinuousInTheMenu() => Sta.Run(() =>
    {
        var viewer = new PageViewer(null);
        Click(viewer, "Arrangement_Click", viewer.TwoPageItem);
        Assert.True(viewer.Surface.Continuous);

        Click(viewer, "Arrangement_Click", viewer.OnePageItem);
        typeof(PageViewer).GetMethod("MoreMenu_Opened", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(viewer, [viewer, new RoutedEventArgs()]);

        Assert.True(viewer.Surface.Continuous);
        Assert.True(viewer.OnePageItem.IsChecked);
        Assert.True(viewer.ContinuousItem.IsChecked);
        Assert.False(viewer.TwoPageItem.IsChecked);
        return Task.CompletedTask;
    });

    [Fact]
    public Task ATabComesBackThroughShowWithItsRotationAndPage() => Sta.Run(() =>
    {
        using var first = NewTab();
        using var second = NewTab();
        var viewer = new PageViewer(null);
        viewer.Show(first);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        viewer.Surface.SetRotation(90);
        int page = first.PageIndex;

        viewer.Show(second);
        Assert.Equal(0, viewer.Surface.Rotation);
        viewer.Show(first);

        Assert.Equal(90, viewer.Surface.Rotation);
        Assert.Equal(page, first.PageIndex);
        return Task.CompletedTask;
    });

    private static DocumentTab TabAsking()
    {
        var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(4)), new FakeRenderer(), null, "a.pdf");
        var document = tab.Document;
        (ViewerSettings.Read(document) with { PageLayout = PageLayout.TwoPageRight }).Write(document);
        document.Catalog["OpenAction"] = PdfDestinations.ToObject(document, new PdfDestination(2))!;
        return tab;
    }

    private static PageViewer ArrangedViewer()
    {
        var viewer = new PageViewer(null);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        return viewer;
    }

    [Fact]
    public Task AFileOpensInTheLayoutAndAtThePageItAsksForAndEachTabKeepsItsOwn() => Sta.Run(() =>
    {
        using var asking = TabAsking();
        using var plain = NewTab();
        var viewer = ArrangedViewer();

        viewer.Show(asking);
        Assert.Equal((2, true, false, 2), (viewer.Surface.Columns, viewer.Surface.Cover, viewer.Surface.Continuous, viewer.Surface.CurrentPage));

        viewer.Show(plain);
        Assert.Equal((1, false, true), (viewer.Surface.Columns, viewer.Surface.Cover, viewer.Surface.Continuous));

        viewer.Show(asking);
        Assert.Equal((2, true, false), (viewer.Surface.Columns, viewer.Surface.Cover, viewer.Surface.Continuous));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ATabThatWasViewedBeforeDoesNotTakeTheFilesLayoutAgain() => Sta.Run(() =>
    {
        using var asking = TabAsking();
        asking.Zoom = 1.5;
        var viewer = ArrangedViewer();

        viewer.Show(asking);

        Assert.Equal(1, viewer.Surface.Columns);
        Assert.Equal(0, viewer.Surface.CurrentPage);
        return Task.CompletedTask;
    });

    private static PageViewer PresentationViewer(DocumentTab tab)
    {
        var viewer = new PageViewer(null);
        viewer.Show(tab);
        viewer.Measure(new Size(800, 600));
        viewer.Arrange(new Rect(0, 0, 800, 600));
        viewer.UpdateLayout();
        return viewer;
    }

    [Fact]
    public Task PresentingShowsOnePageAtATimeWithoutTheBar() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var viewer = PresentationViewer(tab);
        viewer.Surface.SetArrangement(2, true, true);

        viewer.Presenting = true;

        Assert.True(viewer.Presenting);
        Assert.Equal(Visibility.Collapsed, viewer.Bar.Visibility);
        Assert.Equal((1, false, false, FitMode.Page), (viewer.Surface.Columns, viewer.Surface.Cover, viewer.Surface.Continuous, viewer.Surface.Fit));
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheAdvanceAndBackKeysStepPagesAndStopAtTheEnds() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var viewer = PresentationViewer(tab);
        Assert.False(viewer.PresentWithKeys(Key.Right, false));
        viewer.Presenting = true;

        Assert.False(viewer.PresentWithKeys(Key.F, false));
        Assert.True(viewer.PresentWithKeys(Key.Left, false));
        Assert.Equal(0, viewer.Surface.CurrentPage);
        foreach (var key in new[] { Key.Right, Key.Down, Key.PageDown, Key.N, Key.Space })
            Assert.True(viewer.PresentWithKeys(key, false));
        Assert.Equal(2, viewer.Surface.CurrentPage);

        viewer.PresentWithKeys(Key.Space, true);
        Assert.Equal(1, viewer.Surface.CurrentPage);
        viewer.PresentWithKeys(Key.Home, false);
        Assert.Equal(0, viewer.Surface.CurrentPage);
        viewer.PresentWithKeys(Key.End, false);
        Assert.Equal(2, viewer.Surface.CurrentPage);
        return Task.CompletedTask;
    });

    [Fact]
    public Task EscapeLeavesPresentingAndTheViewIsBack() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer(), null, "a.pdf");
        var viewer = PresentationViewer(tab);
        viewer.Surface.SetArrangement(2, true, false);
        viewer.Surface.SetZoom(1.5);
        viewer.Surface.SetRotation(90);

        viewer.Presenting = true;
        Assert.True(viewer.PresentWithKeys(Key.Escape, false));

        Assert.False(viewer.Presenting);
        Assert.Equal(Visibility.Visible, viewer.Bar.Visibility);
        Assert.Equal((2, true, false, FitMode.None, 1.5, 90), (viewer.Surface.Columns, viewer.Surface.Cover, viewer.Surface.Continuous, viewer.Surface.Fit, viewer.Surface.Zoom, viewer.Surface.Rotation));
        return Task.CompletedTask;
    });

    [Fact]
    public Task PresentingWithoutAFileDoesNothing() => Sta.Run(() =>
    {
        var viewer = new PageViewer(null);

        viewer.Presenting = true;

        Assert.False(viewer.Presenting);
        return Task.CompletedTask;
    });
}
