using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Viewer;

/// <summary>
/// The page viewer in the stage: a bar with page, zoom and view controls over the scrolling pages, a find bar and
/// the prompt before an address is opened. The pages themselves are <see cref="PageSurface"/>; this file is the
/// state the bar shows and the properties of <see cref="IDocumentViewer"/>. Going places, the pointer, text and
/// layers are in the partial files.
/// </summary>
public partial class PageViewer : UserControl, IDocumentViewer
{
    private sealed record ViewState(int Rotation, PagePoint? Place, int Columns, bool Cover, bool Continuous);

    private readonly ConditionalWeakTable<DocumentTab, ViewState> _states = new();
    private DocumentTab? _tab;
    private string[] _labels = [];
    private bool _reading;
    private string _shownZoom = "";
    private (int Columns, bool Cover, bool Continuous, FitMode Fit, double Zoom) _beforeReading;
    private (int Columns, bool Cover, bool Continuous) _arrangement = (1, false, true);

    private readonly string? _preferencesDirectory;
    private readonly DispatcherTimer _toast = new();

    public PageViewer() : this(StoreFiles.DefaultDirectory)
    {
    }

    // A null directory keeps the viewer's look out of the settings, for viewers that only compare.
    internal PageViewer(string? preferencesDirectory)
    {
        _preferencesDirectory = preferencesDirectory;
        InitializeComponent();
        Search = new ViewerSearch(TextAsync, () => Surface.CurrentPage, action => Dispatcher.InvokeAsync(action), PageLabel);
        Find.Attach(Search);
        Find.CloseRequested += (_, _) => HideFind();
        Search.Changed += Search_Changed;
        Search.CurrentChanged += Search_CurrentChanged;
        Surface.PageChanged += Surface_PageChanged;
        Surface.OptionsChanged += Surface_OptionsChanged;
        Surface.ViewChanged += Surface_ViewChanged;
        Surface.Decorate = Decorate;
        Surface.PageText = page => LoadedText(page)?.Text;
        Surface.PageLabel = PageLabel;
        Surface.PageLinks = LinkTargets;
        InitInput();
        InitText();
        _toast.Tick += (_, _) => HideToast();
        if (preferencesDirectory is not null)
        {
            var preferences = AppPreferencesStore.Load(preferencesDirectory);
            Surface.SetTint(preferences.Tint);
            Surface.SetArrangement(preferences.Columns == 2 ? 2 : 1, preferences.Cover, preferences.Continuous);
        }
        _arrangement = (Surface.Columns, Surface.Cover, Surface.Continuous);
        foreach (var item in new[] { Preset25, Preset50, Preset75, Preset100, Preset125, Preset150, Preset200, Preset400 })
            item.Header = Loc.T("{0} %", double.Parse((string)item.Tag, System.Globalization.CultureInfo.InvariantCulture) * 100);
        RefreshBar();
    }

    public FrameworkElement View => this;

    public DocumentTab? Tab => _tab;

    public event EventHandler? StateChanged;

    public event EventHandler? ViewChanged;

    public event EventHandler? PageChanged;

    public void Show(DocumentTab? tab)
    {
        Presenting = false;
        if (_tab is not null)
        {
            _tab.Changed -= Tab_Changed;
            _states.AddOrUpdate(_tab, new ViewState(Surface.Rotation, Surface.TopPlace(), Surface.Columns, Surface.Cover, Surface.Continuous));
            _tab.Rotation = Surface.Rotation;
        }
        EndPointerTool();
        _tab = tab;
        _history.Clear();
        ResetText();
        ResetLayers();
        HideFind();
        HideLink();
        HideToast();
        Search.Clear();
        ViewState? state = null;
        if (tab is not null) _states.TryGetValue(tab, out state);
        bool fresh = tab is not null && state is null && tab.Fit == FitMode.None && tab.Zoom == 0;
        var (columns, cover, continuous) = state is null ? _arrangement : (state.Columns, state.Cover, state.Continuous);
        if (fresh && FileLayout(tab!.Document) is { } declared) (columns, cover, continuous) = declared;
        Surface.SetArrangement(columns, cover, continuous);
        Surface.Show(tab, state?.Rotation ?? tab?.Rotation ?? 0, tab is not null && ViewerSettings.Read(tab.Document).RightToLeft);
        if (state?.Place is { } place) Surface.GoToPage(place.Page, place.Point, keepX: true);
        else if (fresh) FollowOpenAction(tab!.Document);
        if (tab is not null)
        {
            tab.Changed += Tab_Changed;
            StoreZoom(tab);
            tab.PageIndex = Surface.CurrentPage;
        }
        ReadLabels();
        Note.Text = Loc.T("This file's pages cannot be shown here. You can still edit and save it.");
        Note.Visibility = tab is { CanDraw: false } ? Visibility.Visible : Visibility.Collapsed;
        RefreshBar();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    // What the file's /PageLayout asks for, or null when it says nothing; a cover only where there is a spread to put it in.
    private static (int Columns, bool Cover, bool Continuous)? FileLayout(PdfDocument document)
    {
        bool spreads = document.Pages.Count >= 2;
        return document.Name(document.Catalog, "PageLayout") switch
        {
            "SinglePage" => (1, false, false),
            "OneColumn" => (1, false, true),
            "TwoColumnLeft" => (2, false, true),
            "TwoColumnRight" => (2, spreads, true),
            "TwoPageLeft" => (2, false, false),
            "TwoPageRight" => (2, spreads, false),
            _ => null,
        };
    }

    // Applies the file's /OpenAction when it is a go-to; scripts and other actions are not run.
    private void FollowOpenAction(PdfDocument document)
    {
        try
        {
            if (PdfActions.ReadDocument(document).OpenAction is not GoToAction go || PdfDestinations.Locate(document, go.Destination) is not { } place) return;
            switch (go.Destination.Fit)
            {
                case DestinationFit.Fit or DestinationFit.FitB:
                    Surface.SetFit(FitMode.Page);
                    break;
                case DestinationFit.FitH or DestinationFit.FitBH:
                    Surface.SetFit(FitMode.Width);
                    break;
                case DestinationFit.Xyz when place.Zoom is { } zoom:
                    Surface.SetZoom(zoom);
                    break;
            }
            Surface.GoToPage(place.PageIndex, new Point(place.X, place.Y));
        }
        catch (PdfReadException)
        {
        }
    }

    private void ShowToast(string text, int milliseconds = 3000)
    {
        if (_tab is null) return;
        ToastText.Text = text;
        Toast.Visibility = Visibility.Visible;
        RaiseLiveRegionChanged(ToastText);
        _toast.Stop();
        _toast.Interval = TimeSpan.FromMilliseconds(milliseconds);
        _toast.Start();
    }

    private void HideToast()
    {
        _toast.Stop();
        Toast.Visibility = Visibility.Collapsed;
    }

    private void Speak(string text)
    {
        if (_tab is null) return;
        Speech.Text = "";
        Speech.Text = text;
        RaiseLiveRegionChanged(Speech);
    }

    private static void RaiseLiveRegionChanged(UIElement element) =>
        (UIElementAutomationPeer.FromElement(element) ?? UIElementAutomationPeer.CreatePeerForElement(element))?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);

    private void Tab_Changed(object? sender, EventArgs e)
    {
        if (_tab is not { } tab) return;
        ResetText();
        ReadLabels();
        Surface.Reload();
        Surface.SetRightToLeft(ViewerSettings.Read(tab.Document).RightToLeft);
        ReapplyLayers();
        Note.Visibility = tab.CanDraw ? Visibility.Collapsed : Visibility.Visible;
        if (Search.Query.Length > 0) _ = Search.Restart();
        RefreshBar();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void StoreZoom(DocumentTab tab)
    {
        tab.Fit = Surface.Fit;
        tab.Rotation = Surface.Rotation;
        tab.Zoom = Surface.Fit == FitMode.None ? Surface.Zoom : 0;
    }

    private void ReadLabels() => _labels = _tab is null ? [] : [.. PdfPageLabels.Labels(_tab.Document)];

    // ----- IDocumentViewer: looking

    public int PageIndex
    {
        get => Surface.CurrentPage;
        set => GoToPage(value);
    }

    public double Zoom
    {
        get => Surface.Zoom;
        set => Surface.SetZoom(value);
    }

    public int PageCount => Surface.PageCount;

    public string PageLabel(int page) => (uint)page < (uint)_labels.Length && _labels[page].Length > 0 ? _labels[page] : (page + 1).ToString();

    public FitMode Fit
    {
        get => Surface.Fit;
        set => Surface.SetFit(value);
    }

    public int Columns
    {
        get => Surface.Columns;
        set => Surface.SetArrangement(value, Surface.Cover, Surface.Continuous);
    }

    public bool CoverPage
    {
        get => Surface.Cover;
        set => Surface.SetArrangement(Surface.Columns, value, Surface.Continuous);
    }

    public bool Continuous
    {
        get => Surface.Continuous;
        set => Surface.SetArrangement(Surface.Columns, Surface.Cover, value);
    }

    public int Rotation
    {
        get => Surface.Rotation;
        set => Surface.SetRotation(value);
    }

    public PageTint Tint
    {
        get => Surface.Tint;
        set => Surface.SetTint(value);
    }

    public bool ReadingMode
    {
        get => _reading;
        set
        {
            if (value == _reading) return;
            _reading = value;
            if (value)
            {
                _beforeReading = (Surface.Columns, Surface.Cover, Surface.Continuous, Surface.Fit, Surface.Zoom);
                Surface.SetArrangement(1, false, true);
                Surface.SetFit(FitMode.Width);
            }
            else
            {
                Surface.SetArrangement(_beforeReading.Columns, _beforeReading.Cover, _beforeReading.Continuous);
                if (_beforeReading.Fit == FitMode.None) Surface.SetZoom(_beforeReading.Zoom);
                else Surface.SetFit(_beforeReading.Fit);
            }
            Bar.Visibility = value ? Visibility.Collapsed : Visibility.Visible;
            ExitReadingButton.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
            if (value) HideFind();
            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public IReadOnlyList<int> VisiblePages => [.. Surface.Layout.PagesIn(Surface.ViewRect)];

    public Size PageSize(int page) => Surface.PageSize(page);

    public PageGeometry Geometry(int page) => Surface.Geometry(page);

    public PageOverlay Overlay(int page) => Surface.Overlay(page);

    public Matrix? PageToView(int page)
    {
        if (Surface.PageMatrix(page) is not { } matrix) return null;
        var origin = Surface.TranslatePoint(new Point(0, 0), this);
        matrix.Translate(origin.X, origin.Y);
        return matrix;
    }

    public PagePoint? ViewToPage(Point view, bool nearest = false)
    {
        var local = TranslatePoint(view, Surface);
        if (local.X < 0 || local.Y < 0 || local.X >= Surface.ActualWidth || local.Y >= Surface.ActualHeight) return null;
        return Surface.Hit(local, nearest) is { } hit ? new PagePoint(hit.Page, hit.Point) : null;
    }

    // ----- The bar

    private void RefreshBar()
    {
        bool open = _tab is not null;
        int page = Surface.CurrentPage;
        if (!PageBox.IsKeyboardFocused) PageBox.Text = open ? PageLabel(page) : "";
        PageCountText.Text = open ? Loc.T("of {0}", Surface.PageCount) : "";
        string zoom = open ? Loc.T("{0} %", Math.Round(Surface.Zoom * 100)) : "";
        _shownZoom = zoom;
        if (!ZoomBox.IsKeyboardFocused) ZoomBox.Text = zoom;
        AutomationProperties.SetName(ZoomBox, open ? $"{Loc.T("Zoom")} {zoom}" : Loc.T("Zoom"));
        PreviousButton.IsEnabled = open && page > 0;
        NextButton.IsEnabled = open && page < Surface.PageCount - 1;
        bool room = Bar.ActualWidth >= 366;
        BackButton.Visibility = ForwardButton.Visibility = room ? Visibility.Visible : Visibility.Collapsed;
        BackButton.IsEnabled = CanGoBack;
        ForwardButton.IsEnabled = CanGoForward;
        foreach (var control in new Control[] { PageBox, ZoomBox, ZoomMenuButton, ZoomInButton, ZoomOutButton, FindButton, MoreButton, SelectButton, HandButton }) control.IsEnabled = open;
        SelectButton.IsChecked = open && Mode == PointerMode.Select && PointerTool is null;
        HandButton.IsChecked = open && Mode == PointerMode.Hand && PointerTool is null;
        MarkChecked(SelectButton);
        MarkChecked(HandButton);
    }

    // The fill alone would vanish where the fill equals the window colour, so the checked one also gets an outline.
    private static void MarkChecked(System.Windows.Controls.Primitives.ToggleButton button)
    {
        if (button.IsChecked == true)
        {
            button.SetResourceReference(Control.BackgroundProperty, "SubtleFillColorSecondaryBrush");
            button.SetResourceReference(Control.BorderBrushProperty, "AccentFillColorDefaultBrush");
        }
        else
        {
            button.Background = System.Windows.Media.Brushes.Transparent;
            button.BorderBrush = System.Windows.Media.Brushes.Transparent;
        }
    }

    private void Bar_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        ModeGroup.Visibility = e.NewSize.Width < 506 ? Visibility.Collapsed : Visibility.Visible;
        ZoomInButton.Visibility = ZoomOutButton.Visibility = e.NewSize.Width < 436 ? Visibility.Collapsed : Visibility.Visible;
        RefreshBar();
    }

    private void Surface_PageChanged(object? sender, EventArgs e)
    {
        RefreshBar();
        PageChanged?.Invoke(this, EventArgs.Empty);
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Surface_OptionsChanged(object? sender, EventArgs e)
    {
        if (_tab is not null) StoreZoom(_tab);
        RefreshBar();
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Surface_ViewChanged(object? sender, EventArgs e)
    {
        _linkTip.IsOpen = false;
        ViewChanged?.Invoke(this, EventArgs.Empty);
        _source?.Retain(Surface.Layout.PageCount == 0 ? 0 : Surface.Layout.PagesIn(Surface.ViewRect).Count());
        PreloadText();
    }

    private void Previous_Click(object sender, RoutedEventArgs e) => StepPage(-1);

    private void Next_Click(object sender, RoutedEventArgs e) => StepPage(1);

    private void Back_Click(object sender, RoutedEventArgs e) => GoBack();

    private void Forward_Click(object sender, RoutedEventArgs e) => GoForward();

    private void ZoomOut_Click(object sender, RoutedEventArgs e) => Surface.SetZoom(ZoomMath.Step(Surface.Zoom, -1));

    private void ZoomIn_Click(object sender, RoutedEventArgs e) => Surface.SetZoom(ZoomMath.Step(Surface.Zoom, 1));

    private void Zoom_Click(object sender, RoutedEventArgs e) => OpenMenu(ZoomMenuButton);

    private void More_Click(object sender, RoutedEventArgs e) => OpenMenu(MoreButton);

    private static void OpenMenu(Button button)
    {
        var menu = button.ContextMenu;
        menu.PlacementTarget = button;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
        menu.IsOpen = true;
    }

    private void ZoomPreset_Click(object sender, RoutedEventArgs e) =>
        Surface.SetZoom(double.Parse((string)((MenuItem)sender).Tag, System.Globalization.CultureInfo.InvariantCulture));

    private void FitWidth_Click(object sender, RoutedEventArgs e) => Surface.SetFit(FitMode.Width);

    private void FitPage_Click(object sender, RoutedEventArgs e) => Surface.SetFit(FitMode.Page);

    private void ActualSize_Click(object sender, RoutedEventArgs e) => Surface.SetZoom(1);

    private void RotateRight_Click(object sender, RoutedEventArgs e) => Surface.SetRotation(Surface.Rotation + 90);

    private void RotateLeft_Click(object sender, RoutedEventArgs e) => Surface.SetRotation(Surface.Rotation - 90);

    private void Tint_Click(object sender, RoutedEventArgs e)
    {
        Surface.SetTint(Enum.Parse<PageTint>((string)((MenuItem)sender).Tag));
        SaveView();
    }

    private void Reading_Click(object sender, RoutedEventArgs e) => ReadingMode = !ReadingMode;

    private void ExitReading_Click(object sender, RoutedEventArgs e) => ReadingMode = false;

    private void FullScreen_Click(object sender, RoutedEventArgs e) => FullScreen = !FullScreen;

    private void Present_Click(object sender, RoutedEventArgs e) => Presenting = !Presenting;

    private void Arrangement_Click(object sender, RoutedEventArgs e)
    {
        int columns = Surface.Columns;
        bool cover = Surface.Cover, continuous = Surface.Continuous;
        switch ((string)((MenuItem)sender).Tag)
        {
            case "single":
                columns = 1;
                break;
            case "continuous":
                continuous = !continuous;
                break;
            case "two":
                columns = 2;
                break;
            case "cover":
                cover = !cover;
                break;
        }
        Surface.SetArrangement(columns, cover, continuous);
        SaveView();
    }

    private void SaveView()
    {
        _arrangement = (Surface.Columns, Surface.Cover, Surface.Continuous);
        if (_preferencesDirectory is null) return;
        AppPreferencesStore.Update(p =>
        {
            p.Tint = Surface.Tint;
            p.Columns = Surface.Columns;
            p.Cover = Surface.Cover;
            p.Continuous = Surface.Continuous;
        }, _preferencesDirectory);
    }

    private void MoreMenu_Opened(object sender, RoutedEventArgs e)
    {
        SelectItem.IsChecked = Mode == PointerMode.Select;
        HandItem.IsChecked = Mode == PointerMode.Hand;
        OnePageItem.IsChecked = Surface.Columns == 1;
        ContinuousItem.IsChecked = Surface.Continuous;
        TwoPageItem.IsChecked = Surface.Columns == 2;
        CoverItem.IsChecked = Surface.Cover;
        CoverItem.IsEnabled = Surface.Columns == 2;
        TintNoneItem.IsChecked = Surface.Tint == PageTint.None;
        TintDarkItem.IsChecked = Surface.Tint == PageTint.Dark;
        TintSepiaItem.IsChecked = Surface.Tint == PageTint.Sepia;
        ReadingItem.IsChecked = _reading;
        FullScreenItem.IsChecked = FullScreen;
        PresentItem.IsChecked = _presenting;
        ForgetLinksItem.IsEnabled = _preferencesDirectory is not null && AppPreferencesStore.Load(_preferencesDirectory).AllowedLinkHosts.Count > 0;
    }

    private void Find_Click(object sender, RoutedEventArgs e) => ShowFind();

    private void Select_Click(object sender, RoutedEventArgs e) => SetMode(PointerMode.Select);

    private void Hand_Click(object sender, RoutedEventArgs e) => SetMode(PointerMode.Hand);
}
