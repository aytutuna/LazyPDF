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
    private bool _refreshAgain;
    private DocumentTab? _shownTab;
    private InfoMessage? _messageShown;
    private bool _homeShown;
    private string _statusShown = "";

    public MainWindow() : this(NewViewModel(out var thumbnails), thumbnails)
    {
    }

    public MainWindow(AppViewModel viewModel, Thumbnails? thumbnails)
    {
        InitializeComponent();
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
        Loaded += Window_Loaded;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var work = SystemParameters.WorkArea;
        var saved = AppPreferencesStore.Load().Window;
        Rect bounds = saved is null
            ? new Rect(0, 0, Math.Min(1200, work.Width), Math.Min(800, work.Height))
            : new Rect(saved.Left, saved.Top, saved.Width, saved.Height);
        if (saved is null)
        {
            bounds.X = work.X + (work.Width - bounds.Width) / 2;
            bounds.Y = work.Y + (work.Height - bounds.Height) / 2;
        }
        bounds = Fit(bounds, new Rect(SystemParameters.VirtualScreenLeft, SystemParameters.VirtualScreenTop,
            SystemParameters.VirtualScreenWidth, SystemParameters.VirtualScreenHeight), work);
        Left = bounds.X;
        Top = bounds.Y;
        Width = bounds.Width;
        Height = bounds.Height;
        if (saved?.Maximized == true) WindowState = WindowState.Maximized;
    }

    // Sizes below match MinWidth and MinHeight in MainWindow.xaml.
    internal static Rect Fit(Rect saved, Rect virtualScreen, Rect workArea)
    {
        double width = Math.Max(700, Math.Min(saved.Width, workArea.Width));
        double height = Math.Max(560, Math.Min(saved.Height, workArea.Height));
        double shown = Math.Min(saved.Right, virtualScreen.Right) - Math.Max(saved.Left, virtualScreen.Left);
        bool topShown = shown >= 100 && saved.Top >= virtualScreen.Top && saved.Top < virtualScreen.Bottom - 40;
        if (!topShown)
            return new Rect(workArea.X + (workArea.Width - width) / 2, workArea.Y + (workArea.Height - height) / 2, width, height);
        return new Rect(saved.X, saved.Y, width, height);
    }

    private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => RefreshFromViewModel();

    private void ViewModel_ExitRequested(object? sender, EventArgs e) => Close();

    private void ToolStrip_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateToolStripMode(e.NewSize.Width);

    private static AppViewModel NewViewModel(out Thumbnails thumbnails)
    {
        Func<IDocumentRenderer> renderers = () => new WindowsPageRenderer();
        thumbnails = new Thumbnails(renderers);
        return new AppViewModel(renderers, new WicImageCodec(), new SystemFontSource(), new SisterApps());
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _vm.CheckRecovery();
        RefreshFromViewModel();
        OpenFiles(App.StartupFiles);
    }

    /// <summary>Opens the files (from the command line or a second start) and brings the window forward; no files just brings it forward.</summary>
    public void OpenFiles(IReadOnlyList<string> paths)
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        if (paths.Count > 0) OpenOrHold(paths);
    }

    public void ShowProblem(Problem problem) => _vm.ShowProblem(problem);

    private void RefreshFromViewModel()
    {
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
            TabList.SelectedItem = _vm.ActiveTab;
            Home.Visibility = home ? Visibility.Visible : Visibility.Collapsed;
            Workspace.Visibility = home ? Visibility.Collapsed : Visibility.Visible;
            ToolStrip.Visibility = home ? Visibility.Collapsed : Visibility.Visible;
            if (home) Home.Show(_vm.Tiles, _vm.Recent);
            if (home && !_homeShown) Dispatcher.BeginInvoke(FocusHome, System.Windows.Threading.DispatcherPriority.Loaded);
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
        StatusText.Text = _vm.IsBusy ? _vm.BusyText : _vm.StatusShort;
        string spoken = _vm.IsBusy ? _vm.BusyText : _vm.StatusFull;
        AutomationProperties.SetName(StatusText, spoken);
        if (spoken != _statusShown)
        {
            _statusShown = spoken;
            if (spoken.Length > 0) Announce(StatusText);
        }
        BusyBar.Visibility = CancelButton.Visibility = _vm.IsBusy ? Visibility.Visible : Visibility.Collapsed;
        if (tab is null)
        {
            PageText.Text = PageBoxText.Text = ZoomText.Text = "";
            NameReadouts();
            return;
        }
        int index = Math.Clamp(tab.PageIndex, 0, Math.Max(0, tab.PageCount - 1));
        string label = _viewer.PageLabel(index);
        PageText.Text = label == (index + 1).ToString()
            ? Loc.T("Page {0} of {1}", index + 1, tab.PageCount)
            : Loc.T("Page {0} ({1} of {2})", label, index + 1, tab.PageCount);
        var size = new LazyPDF.Core.PageGeometry(tab.Document.Pages[index]);
        PageBoxText.Text = System.Globalization.RegionInfo.CurrentRegion.IsMetric
            ? Loc.T("{0} × {1} mm", Math.Round(size.Width * 25.4 / 72), Math.Round(size.Height * 25.4 / 72))
            : Loc.T("{0} × {1} in", Math.Round(size.Width / 72, 1), Math.Round(size.Height / 72, 1));
        double zoom = ReferenceEquals(_shownTab, tab) ? _viewer.Zoom : tab.Zoom;
        ZoomText.Text = Loc.T("{0} %", Math.Round(zoom * 100));
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

    private void Cancel_Click(object sender, RoutedEventArgs e) => _vm.CancelBusy();

    private void Window_Activated(object? sender, EventArgs e) => _ = _vm.CheckDiskAsync();

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!HandInTyping(_vm.ActiveDocument) || !_vm.RequestExit())
        {
            e.Cancel = true;
            return;
        }
        // RestoreBounds is empty once the window has closed, so the place is taken here.
        var normal = WindowState == WindowState.Normal ? new Rect(Left, Top, Width, Height) : RestoreBounds;
        bool maximized = WindowState == WindowState.Maximized;
        AppPreferencesStore.Update(p => p.Window = new WindowPlacement
        {
            Left = normal.X, Top = normal.Y, Width = normal.Width, Height = normal.Height, Maximized = maximized,
        });
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
        return tab is null || !ReferenceEquals(tab, _vm.ActiveDocument) || _inspectorPanel?.HandIn() != false;
    }

    private void RequestClose(DocumentTab tab)
    {
        if (HandInTyping(tab)) _vm.RequestClose(tab);
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
                case Key.P: _vm.Print(); break;
                case Key.F when _vm.ActiveDocument is not null && _vm.HeldStage is null: _viewer.ShowFind(); break;
                case Key.G when _vm.ActiveDocument is not null && _vm.HeldStage is null: _viewer.ShowGoToPage(); break;
                case Key.Z when shift: Redo(); break;
                case Key.Z: Undo(); break;
                case Key.Y: Redo(); break;
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
        if (_inspectorPanel?.HandIn() == false) return;
        int index = _vm.Strip.IndexOf(_vm.ActiveTab);
        _vm.ActiveTab = _vm.Strip[(index + step + _vm.Strip.Count) % _vm.Strip.Count];
    }
}
