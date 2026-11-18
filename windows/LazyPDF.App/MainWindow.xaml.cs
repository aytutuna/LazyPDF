using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Batch;
using LazyPDF.App.Tools.Create;
using LazyPDF.App.Viewer;

namespace LazyPDF.App;

// The window: it builds the services, hands them to the view model and draws the view model's state again
// whenever it changes (RefreshFromViewModel). Tabs, tools, files and the overlays are in the partial files.
public partial class MainWindow : Window
{
    private readonly AppViewModel _vm;
    private readonly IDocumentViewer _viewer = ViewerFactory.Create();
    private bool _refreshing;
    private List<DocumentTab>? _exitTabs;
    private DocumentTab? _exitActive;
    private bool _refreshAgain;
    private DocumentTab? _shownTab;
    private InfoMessage? _messageShown;
    private bool _homeShown;
    private string _statusShown = "";

    private readonly Point? _opensAt;

    /// <summary>The first window does the start-up work: the crash offer, the files of the command line and of the last session. A secondary one starts empty, at <paramref name="at"/> or beside the window in use.</summary>
    public MainWindow(DocumentRegistry registry, RecoveryStore recovery, bool primary = true, Point? at = null)
        : this(NewViewModel(out var thumbnails, registry, recovery), thumbnails, primary, at)
    {
    }

    public MainWindow(AppViewModel viewModel, Thumbnails? thumbnails, bool primary = true, Point? at = null)
    {
        InitializeComponent();
        IsPrimary = primary;
        _opensAt = at;
        if (!primary) WindowStartupLocation = WindowStartupLocation.Manual;
        _vm = viewModel;
        Home.Thumbnails = thumbnails;
        Home.TileChosen += Home_TileChosen;
        Home.FileChosen += Home_FileChosen;
        Home.FileForgotten += Home_FileForgotten;
        Home.FilePinChanged += Home_FilePinChanged;
        Home.RecentCleared += Home_RecentCleared;
        ViewerHost.Content = _viewer.View;
        _viewer.StateChanged += Viewer_StateChanged;
        TabList.ItemsSource = _vm.Strip;
        BuildToolStrip();
        BuildRail();
        _vm.PropertyChanged += ViewModel_PropertyChanged;
        _vm.ExitRequested += ViewModel_ExitRequested;
        _vm.ToolOpened += (_, _) => FocusInspector();
        _vm.CloseRequested += (_, tab) => RequestClose(tab);
        _vm.SystemPrintRequested += ViewModel_SystemPrintRequested;
        _vm.Released += ViewModel_Released;
        _vm.DialogOwner = this;
        _vm.BringForward = _ => OpenFiles([]);
        WindowHub.Register(this);
        Closed += (_, _) =>
        {
            WindowHub.Unregister(this);
            _vm.LeaveRegistry();
        };
        Loaded += Window_Loaded;
    }

    public bool IsPrimary { get; }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var work = SystemParameters.WorkArea;
        var saved = AppPreferencesStore.Load().Window;
        var screen = new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop, SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight);
        if (!IsPrimary)
        {
            // The saved place is the first window's; another one takes its size and goes where it was asked to or beside the window in use.
            var size = saved is null ? new Size(Math.Min(1200, work.Width), Math.Min(800, work.Height)) : new Size(saved.Width, saved.Height);
            var beside = WindowHub.Active is { } active
                ? active.WindowState == WindowState.Maximized ? active.RestoreBounds : new Rect(active.Left, active.Top, active.Width, active.Height)
                : (Rect?)null;
            var placed = SecondaryBounds(size, _opensAt, beside, screen, work);
            (Left, Top, Width, Height) = (placed.X, placed.Y, placed.Width, placed.Height);
            return;
        }
        Rect bounds = saved is null
            ? new Rect(0, 0, Math.Min(1200, work.Width), Math.Min(800, work.Height))
            : new Rect(saved.Left, saved.Top, saved.Width, saved.Height);
        if (saved is null)
        {
            bounds.X = work.X + (work.Width - bounds.Width) / 2;
            bounds.Y = work.Y + (work.Height - bounds.Height) / 2;
        }
        bounds = Fit(bounds, screen, work);
        Left = bounds.X;
        Top = bounds.Y;
        Width = bounds.Width;
        Height = bounds.Height;
        if (saved?.Maximized == true) WindowState = WindowState.Maximized;
    }

    // Windows are told apart by the document in view in the taskbar, Alt+Tab and a screen reader.
    internal static string TitleOf(DocumentTab? tab) => tab is null ? "Lazy PDF" : $"{tab.Title} - Lazy PDF";

    // Sizes below match MinWidth and MinHeight in MainWindow.xaml.
    internal static string PageReadout(string label, int index, int count) =>
        label == (index + 1).ToString()
            ? Loc.T("Page {0} of {1}", index + 1, count)
            : Loc.T("Page {0} ({1} of {2})", label, index + 1, count);

    // A tab that is not shown keeps 0 while it fits the width or page; there is no number to give.
    internal static string ZoomReadout(double zoom) => zoom > 0 ? Loc.T("{0} %", Math.Round(zoom * 100)) : "";

    internal static string SizeReadout(double widthPt, double heightPt, bool metric) => metric
        ? Loc.T("{0} × {1} mm", Math.Round(widthPt * 25.4 / 72), Math.Round(heightPt * 25.4 / 72))
        : Loc.T("{0} × {1} in", Math.Round(widthPt / 72, 1), Math.Round(heightPt / 72, 1));

    internal static Rect SecondaryBounds(Size size, Point? at, Rect? beside, Rect screen, Rect work)
    {
        const double Cascade = 32;
        var origin = at ?? (beside is { } b ? new Point(b.X + Cascade, b.Y + Cascade) : new Point(work.X + (work.Width - size.Width) / 2, work.Y + (work.Height - size.Height) / 2));
        return Fit(new Rect(origin, size), screen, work);
    }

    internal static Rect Fit(Rect saved, Rect virtualScreen, Rect workArea)
    {
        double shown = Math.Min(saved.Right, virtualScreen.Right) - Math.Max(saved.Left, virtualScreen.Left);
        bool topShown = shown >= 100 && saved.Top >= virtualScreen.Top && saved.Top < virtualScreen.Bottom - 40;
        if (!topShown)
        {
            double w = Math.Max(700, Math.Min(saved.Width, workArea.Width));
            double h = Math.Max(560, Math.Min(saved.Height, workArea.Height));
            return new Rect(workArea.X + (workArea.Width - w) / 2, workArea.Y + (workArea.Height - h) / 2, w, h);
        }
        // The work area is the primary monitor's only; a window kept on a larger second screen must not shrink.
        return new Rect(saved.X, saved.Y, Math.Max(700, Math.Min(saved.Width, virtualScreen.Width)),
            Math.Max(560, Math.Min(saved.Height, virtualScreen.Height)));
    }

    private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => RefreshFromViewModel();

    // Narrow, a panel can stay attached to a tab that is no longer shown; it must not hand text to a tab another window now owns.
    private void ViewModel_Released(object? sender, DocumentTab tab)
    {
        if (ReferenceEquals(_inspectorTab, tab))
        {
            _inspectorPanel?.Detach();
            _inspectorPanel = null;
            _inspectorTab = null;
        }
        if (ReferenceEquals(_sideTab, tab))
        {
            _sidePanel?.Detach();
            _sidePanel = null;
            _sideTab = null;
        }
        if (ReferenceEquals(_shownTab, tab) && _viewer.FullScreen) _viewer.FullScreen = false;
    }

    private void ViewModel_ExitRequested(object? sender, EventArgs e) => Close();

    private void ToolStrip_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateToolStripMode(e.NewSize.Width);

    private static AppViewModel NewViewModel(out Thumbnails thumbnails, DocumentRegistry registry, RecoveryStore recovery)
    {
        Func<IDocumentRenderer> renderers = () => new WindowsPageRenderer();
        thumbnails = new Thumbnails(renderers);
        return new AppViewModel(renderers, new WicImageCodec(), new SystemFontSource(), new SisterApps(), recovery: recovery, registry: registry);
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        WindowHub.Active = this;
        if (!IsPrimary)
        {
            RefreshFromViewModel();
            return;
        }
        _vm.CheckRecovery();
        RefreshFromViewModel();
        OpenFiles(App.StartupFiles);
        var preferences = AppPreferencesStore.Load();
        // A crash offer comes first and wins.
        if (!preferences.ReopenLast || App.StartupFiles.Count > 0 || _vm.RecoveryOffer is not null) return;
        // A share that is offline can make each check wait, so they run off the UI thread.
        var (files, last) = await Task.Run(() => (preferences.LastFiles.Where(File.Exists).ToList(),
            preferences.LastActive is { } a && File.Exists(a) ? a : null));
        await _vm.OpenFilesAsync(files);
        if (last is not null) await _vm.OpenAsync(last);
    }

    /// <summary>Opens the files (from the command line or a second start) and brings the window forward; no files just brings it forward.</summary>
    public void OpenFiles(IReadOnlyList<string> paths)
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        if (paths.Count > 0) OpenOrHold(paths);
    }

    public void ShowProblem(Problem problem) => _vm.ShowProblem(problem);

    private void ForgetExitSession()
    {
        // This window was closing for good and no longer is.
        if (_exitTabs is not null) WindowHub.EndExit();
        _exitTabs = null;
        _exitActive = null;
    }

    private void RefreshFromViewModel()
    {
        // An exit that was called off leaves nothing to keep.
        if (!_vm.IsExiting) ForgetExitSession();
        if (_refreshing)
        {
            _refreshAgain = true;
            return;
        }
        _refreshing = true;
        try
        {
            do
            {
                _refreshAgain = false;
                RefreshAll();
            }
            while (_refreshAgain);
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void RefreshAll()
    {
        {
            bool home = _vm.IsHome;
            HookTabPanel();
            Title = TitleOf(_vm.ActiveDocument);
            TabList.SelectedItem = _vm.ActiveTab;
            Home.Visibility = home ? Visibility.Visible : Visibility.Collapsed;
            Workspace.Visibility = home ? Visibility.Collapsed : Visibility.Visible;
            ToolStrip.Visibility = home ? Visibility.Collapsed : Visibility.Visible;
            if (home) Home.Show(_vm.Tiles, _vm.Recent);
            if (home && !_homeShown)
            {
                _ = Home.RecheckAsync();
                Dispatcher.BeginInvoke(FocusHome, System.Windows.Threading.DispatcherPriority.Loaded);
            }
            _homeShown = home;
            ViewerHost.Content = _vm.HeldStage ?? _viewer.View;
            if (!ReferenceEquals(_shownTab, _vm.ActiveDocument))
            {
                _shownTab = _vm.ActiveDocument;
                _viewer.Show(_shownTab);
            }
            RefreshButtons();
            RefreshInfoBar();
            RefreshToolStrip();
            RefreshSidePane();
            RefreshInspector();
            RefreshStatus();
            RefreshOverlays();
            ReleaseHeld();
        }
    }

    private void RefreshButtons()
    {
        var tab = _vm.ActiveDocument;
        SaveButton.IsEnabled = tab is not null && !_vm.IsBusy;
        SaveMenuButton.IsEnabled = tab is not null && !_vm.IsBusy;
        PrintButton.IsEnabled = tab is not null;
        PrintButton.ToolTip = Loc.T(_vm.PrintsInLazyPrint ? "Lazy Print (Ctrl+P)" : "Print (Ctrl+P)");
        AutomationProperties.SetName(PrintButton, Loc.T(_vm.PrintsInLazyPrint ? "Lazy Print" : "Print"));
        UndoButton.IsEnabled = _vm.CanUndo && !_vm.IsBusy;
        RedoButton.IsEnabled = _vm.CanRedo && !_vm.IsBusy;
        UndoButton.ToolTip = _vm.UndoLabel is { Length: > 0 } undo ? Loc.T("Undo {0} (Ctrl+Z)", undo) : Loc.T("Undo (Ctrl+Z)");
        RedoButton.ToolTip = _vm.RedoLabel is { Length: > 0 } redo ? Loc.T("Redo {0} (Ctrl+Y)", redo) : Loc.T("Redo (Ctrl+Y)");
    }

    private void RefreshInfoBar()
    {
        if (_vm.Message is not { } message)
        {
            InfoBar.Visibility = Visibility.Collapsed;
            _messageShown = null;
            return;
        }
        InfoBar.Visibility = Visibility.Visible;
        InfoBar.SetResourceReference(Border.BackgroundProperty, message.IsError ? "SystemFillColorCriticalBackgroundBrush" : "SystemFillColorAttentionBackgroundBrush");
        InfoBarGlyph.Text = message.IsError ? "\uEB90" : "\uE946";
        InfoBarGlyph.SetResourceReference(TextBlock.ForegroundProperty, message.IsError ? "SystemFillColorCriticalBrush" : "SystemFillColorAttentionBrush");
        InfoBarTitle.Text = message.Title;
        InfoBarMessage.Text = message.Text;
        InfoBarAction.Visibility = message.Action is null ? Visibility.Collapsed : Visibility.Visible;
        InfoBarAction.Content = message.Action?.Text;
        InfoBarAction.IsEnabled = !_vm.IsBusy;
        if (ReferenceEquals(message, _messageShown)) return;
        _messageShown = message;
        AutomationProperties.SetName(InfoBarText, $"{message.Title}. {message.Text}");
        Announce(InfoBarText);
    }

    private static void Announce(TextBlock text)
    {
        var peer = UIElementAutomationPeer.FromElement(text) ?? UIElementAutomationPeer.CreatePeerForElement(text);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void RefreshStatus()
    {
        var tab = _vm.ActiveDocument;
        var opening = _vm.IsBusy ? null : _vm.Opening;
        string running = opening is null ? _vm.BusyText : Loc.T("Opening {0}…", opening.Name);
        StatusText.Text = _vm.IsBusy || opening is not null ? running : _vm.StatusShort;
        string spoken = _vm.IsBusy || opening is not null ? running : _vm.StatusFull;
        AutomationProperties.SetName(StatusText, spoken);
        if (spoken != _statusShown)
        {
            _statusShown = spoken;
            if (spoken.Length > 0) Announce(StatusText);
        }
        BusyBar.Visibility = CancelButton.Visibility = _vm.IsBusy || opening is not null ? Visibility.Visible : Visibility.Collapsed;
        if (opening is not null)
        {
            BusyBar.IsIndeterminate = opening.Fraction is null;
            BusyBar.Maximum = 100;
            BusyBar.Value = (opening.Fraction ?? 0) * 100;
        }
        else
        {
            BusyBar.IsIndeterminate = true;
        }
        if (tab is null)
        {
            PageText.Text = PageBoxText.Text = ZoomText.Text = "";
            NameReadouts();
            return;
        }
        int index = Math.Clamp(tab.PageIndex, 0, Math.Max(0, tab.PageCount - 1));
        string label = _viewer.PageLabel(index);
        PageText.Text = PageReadout(label, index, tab.PageCount);
        var size = new LazyPDF.Core.PageGeometry(tab.Document.Pages[index]);
        PageBoxText.Text = SizeReadout(size.Width, size.Height, System.Globalization.RegionInfo.CurrentRegion.IsMetric);
        double zoom = ReferenceEquals(_shownTab, tab) ? _viewer.Zoom : tab.Zoom;
        ZoomText.Text = ZoomReadout(zoom);
        NameReadouts();
    }

    // A reader says the label with the value; a name alone would hide the number.
    private void NameReadouts()
    {
        AutomationProperties.SetName(PageBoxText, PageBoxText.Text.Length == 0 ? "" : $"{Loc.T("Page size")} {PageBoxText.Text}");
        AutomationProperties.SetName(ZoomText, ZoomText.Text.Length == 0 ? "" : $"{Loc.T("Zoom")} {ZoomText.Text}");
    }

    private void FocusHome()
    {
        if (!Modal && _vm.IsHome) Home.FocusDefaultTile();
    }

    private void Viewer_StateChanged(object? sender, EventArgs e) => RefreshStatus();

    private void Home_TileChosen(object? sender, string id)
    {
        if (id == AppViewModel.OpenTile) OpenWithDialog();
        else if (id == AppViewModel.CreateTile) _ = CreateWindow.RunAsync(this, _vm);
        else if (id == "combine" && !_vm.Documents.Any()) OpenWithDialog(() => _vm.StartTile(id));
        else if (id == AppViewModel.BatchTile) BatchWindow.Open(this, _vm);
        else
        {
            _vm.StartTile(id);
            if (_vm.ActiveTool is not null) FocusInspector();
        }
    }

    private void FocusInspector() =>
        Dispatcher.BeginInvoke(() => InspectorHost.MoveFocus(new TraversalRequest(FocusNavigationDirection.First)), System.Windows.Threading.DispatcherPriority.Loaded);

    private void Home_FileChosen(object? sender, string path) => _ = _vm.OpenAsync(path);

    private void Home_FileForgotten(object? sender, string path)
    {
        _vm.ForgetRecent(path);
        Home.Thumbnails?.Forget(path);
    }

    private void Home_FilePinChanged(object? sender, (string Path, bool Pinned) e) => _vm.SetPinned(e.Path, e.Pinned);

    private void Home_RecentCleared(object? sender, EventArgs e)
    {
        _vm.ClearRecent();
        Home.Thumbnails?.Clear();
    }

    private void InfoBarClose_Click(object sender, RoutedEventArgs e) => _vm.DismissMessage();

    private void InfoBarAction_Click(object sender, RoutedEventArgs e)
    {
        var action = _vm.Message?.Action;
        _vm.DismissMessage();
        action?.Run();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (_vm.IsBusy) _vm.CancelBusy();
        else _vm.CancelOpening();
    }

    private void Window_Activated(object? sender, EventArgs e)
    {
        // Activated fires before Loaded, which sets it for a window that has just opened.
        if (IsLoaded) WindowHub.Active = this;
        _ = _vm.CheckDiskAsync();
    }

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        // Files still held would be lost, so the window stays and they open.
        if (_held.Count > 0)
        {
            e.Cancel = true;
            _vm.CancelClose();
            ReleaseHeld(true);
            if (_held.Count > 0) _vm.ShowNotice(Loc.T("Still working"), Loc.T("Wait for the job to end, or cancel it, then close."));
            return;
        }
        if (AsksAboutOwnedWork(_exitTabs is not null, _vm.HasOwnedWork, WindowHub.Exiting))
        {
            string question = Loc.T(Tools.Batch.BatchWindow.IsRunning(_vm) ? "A batch is running. Close anyway?" : "A comparison window is open. Close anyway?");
            if (MessageBox.Show(this, question, "Lazy PDF", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }
        // Handing in can show a notice, which forgets the session, so it comes first.
        if (!HandInTyping(_vm.ActiveDocument))
        {
            e.Cancel = true;
            if (!_vm.IsExiting) ForgetExitSession();
            return;
        }
        // Answering the exit question closes the tabs one by one, so the session is taken before it starts.
        var tabs = _exitTabs ??= _vm.Documents.ToList();
        _exitActive ??= _vm.ActiveDocument;
        if (!_vm.RequestExit())
        {
            e.Cancel = true;
            if (!_vm.IsExiting) ForgetExitSession();
            return;
        }
        var session = tabs.Where(d => d.Path is not null).Select(d => d.Path!).ToList();
        // A window closed a moment ago in this pass: the taskbar's Close all windows, so the files of all of them are written once.
        if (!WindowHub.Exiting && WindowHub.ClosedTogether) WindowHub.BeginExit(_vm.Registry);
        if (WindowHub.Windows.Count > 1 && !WindowHub.Exiting)
        {
            // One window of several closing on purpose: its files are not part of the next start, but Ctrl+Shift+T in the window that stays brings them back.
            if (WindowHub.Survivor(this) is { } stays)
                foreach (string path in session) stays._vm.RememberClosed(path);
            WindowHub.NoteClosed(session, _exitActive?.Path);
            return;
        }
        // The first window's place is the one the next start uses.
        if (WindowHub.Exiting && !IsPrimary) return;
        // RestoreBounds is empty once the window has closed, so the place is taken here.
        var placement = PlacementOf(WindowState == WindowState.Maximized, new Rect(Left, Top, Width, Height), RestoreBounds);
        string? active = _exitActive?.Path;
        // When the whole app ends, the session was written once for every window already.
        bool keepSession = !WindowHub.Exiting;
        AppPreferencesStore.Update(p =>
        {
            p.Window = placement;
            if (!keepSession) return;
            // Nothing is kept without consent.
            p.LastFiles = p.ReopenLast ? session : [];
            p.LastActive = p.ReopenLast ? active : null;
        });
    }

    // Once the unsaved questions have begun the tabs are being closed, and the window comes back to Closing when they are answered.
    internal static bool AsksAboutOwnedWork(bool exitUnderway, bool hasOwnedWork, bool appEnding) => !exitUnderway && hasOwnedWork && !appEnding;

    internal static WindowPlacement PlacementOf(bool maximized, Rect current, Rect restore)
    {
        var normal = maximized ? restore : current;
        return new WindowPlacement
        {
            Left = normal.X, Top = normal.Y, Width = normal.Width, Height = normal.Height, Maximized = maximized,
        };
    }

    // Text still being typed in a tool has to be in the document before the question about unsaved changes.
    // False while a job is running or typed text waits for an answer.
    private bool HandInTyping(DocumentTab? tab)
    {
        if (_actionRunning)
        {
            _vm.ShowNotice(Loc.T("Still working"), Loc.T("Wait for the job to end, or cancel it, then close."));
            return false;
        }
        return tab is null || !ReferenceEquals(tab, _vm.ActiveDocument) || HandedIn();
    }

    private void RequestClose(DocumentTab tab)
    {
        if (HandInTyping(tab)) _vm.RequestClose(tab);
    }

    private void RequestCloseMany(IEnumerable<DocumentTab> tabs)
    {
        if (HandInTyping(_vm.ActiveDocument)) _vm.RequestCloseMany(tabs);
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        // AltGr arrives as Ctrl+Alt, so a key typed with it is not a shortcut.
        if ((Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt)) == ModifierKeys.Control && !Modal && !_actionRunning && !_vm.IsBusy)
        {
            bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
            switch (e.Key)
            {
                case Key.Z or Key.Y when Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase or PasswordBox: return;
                case Key.O: OpenWithDialog(); break;
                case Key.S when shift: SaveAsWithDialog(); break;
                case Key.S: SaveWithDialog(); break;
                case Key.W when _vm.ActiveDocument is { } open: RequestClose(open); break;
                case Key.T when shift: _ = _vm.ReopenClosedAsync(); break;
                case Key.P: _vm.Print(); break;
                case Key.F when _vm.ActiveDocument is not null && _vm.HeldStage is null: _viewer.ShowFind(); break;
                case Key.G when _vm.ActiveDocument is not null && _vm.HeldStage is null: _viewer.ShowGoToPage(); break;
                case Key.Z when shift: Redo(); break;
                case Key.Z: Undo(); break;
                case Key.Y when !shift: Redo(); break;
                case Key.Tab: CycleTab(shift ? -1 : 1); break;
                case Key.PageDown: CycleTab(1); break;
                case Key.PageUp: CycleTab(-1); break;
                default: return;
            }
            e.Handled = true;
        }
    }

    private void CycleTab(int step)
    {
        if (!HandedInOnSwitch()) return;
        int index = _vm.Strip.IndexOf(_vm.ActiveTab);
        _vm.ActiveTab = _vm.Strip[(index + step + _vm.Strip.Count) % _vm.Strip.Count];
    }
}
