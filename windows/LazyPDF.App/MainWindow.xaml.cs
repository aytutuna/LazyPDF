using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;

namespace LazyPDF.App;

// The window: it builds the services, hands them to the view model and draws the view model's state again
// whenever it changes (RefreshFromViewModel). Tabs, tools, files and the overlays are in the partial files.
public partial class MainWindow : Window
{
    private readonly AppViewModel _vm;
    private readonly IDocumentViewer _viewer = ViewerFactory.Create();
    private bool _refreshing;
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
        Home.RecentCleared += Home_RecentCleared;
        ViewerHost.Content = _viewer.View;
        _viewer.StateChanged += Viewer_StateChanged;
        TabList.ItemsSource = _vm.Strip;
        BuildToolStrip();
        BuildRail();
        _vm.PropertyChanged += ViewModel_PropertyChanged;
        _vm.ExitRequested += ViewModel_ExitRequested;
        _vm.SystemPrintRequested += ViewModel_SystemPrintRequested;
        Loaded += Window_Loaded;
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
        if (paths.Count > 0) _ = _vm.OpenFilesAsync(paths);
    }

    private void RefreshFromViewModel()
    {
        if (_refreshing) return;
        _refreshing = true;
        try
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
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void RefreshButtons()
    {
        var tab = _vm.ActiveDocument;
        SaveButton.IsEnabled = tab is not null;
        SaveMenuButton.IsEnabled = tab is not null;
        PrintButton.IsEnabled = tab is not null;
        UndoButton.IsEnabled = _vm.CanUndo;
        RedoButton.IsEnabled = _vm.CanRedo;
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
        PageText.Text = Loc.T("Page {0} of {1}", index + 1, tab.PageCount);
        var size = new LazyPDF.Core.PageGeometry(tab.Document.Pages[index]);
        PageBoxText.Text = Loc.T("{0} × {1} pt", Math.Round(size.Width), Math.Round(size.Height));
        ZoomText.Text = tab.Zoom > 0 ? Loc.T("{0} %", Math.Round(tab.Zoom * 100)) : Loc.T("Fit");
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
        else _vm.StartTile(id);
    }

    private void Home_FileChosen(object? sender, string path) => _ = _vm.OpenAsync(path);

    private void Home_FileForgotten(object? sender, string path) => _vm.ForgetRecent(path);

    private void Home_RecentCleared(object? sender, EventArgs e) => _vm.ClearRecent();

    private void InfoBarClose_Click(object sender, RoutedEventArgs e) => _vm.DismissMessage();

    private void InfoBarAction_Click(object sender, RoutedEventArgs e)
    {
        var action = _vm.Message?.Action;
        _vm.DismissMessage();
        action?.Run();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => _vm.CancelBusy();

    private void Window_Activated(object? sender, EventArgs e) => _vm.CheckDisk();

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (!_vm.RequestExit()) e.Cancel = true;
    }

    private void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && !Modal && !_actionRunning)
        {
            bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
            switch (e.Key)
            {
                case Key.Z or Key.Y when Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase or PasswordBox: return;
                case Key.O: OpenWithDialog(); break;
                case Key.S when shift: SaveAsWithDialog(); break;
                case Key.S: SaveWithDialog(); break;
                case Key.W when _vm.ActiveDocument is { } open: _vm.RequestClose(open); break;
                case Key.P: _vm.Print(); break;
                case Key.F when _vm.ActiveDocument is not null: _viewer.ShowFind(); break;
                case Key.G when _vm.ActiveDocument is not null: _viewer.ShowGoToPage(); break;
                case Key.Z: _vm.Undo(); break;
                case Key.Y: _vm.Redo(); break;
                case Key.Tab: CycleTab(shift ? -1 : 1); break;
                default: return;
            }
            e.Handled = true;
        }
    }

    private void CycleTab(int step)
    {
        int index = _vm.Strip.IndexOf(_vm.ActiveTab);
        _vm.ActiveTab = _vm.Strip[(index + step + _vm.Strip.Count) % _vm.Strip.Count];
    }
}
