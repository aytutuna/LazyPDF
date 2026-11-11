using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>
/// The pages in a grid small enough for the inspector, to select, drag into a new order and change from the bar
/// above; below are the jobs that need a choice first (insert, crop, resize, page labels). The button on top
/// opens the same grid on the stage.
/// </summary>
public partial class PagesPanel : ToolPanel
{
    // The size of a tile in the grid and of the page picture in it. The grid works out which tiles are in view from these.
    public const double TileWidth = 108;
    public const double TileHeight = 160;
    private const double BoxWidth = 92;
    private const double BoxHeight = 124;
    public const double ColumnStep = TileWidth + 8;
    public const double RowStep = TileHeight + 6;

    private OrganizeView? _organize;
    private bool _syncing;
    private bool _boxSelected;
    private IEnumerable<int>? _reselect;
    private double _dpr = 1;

    public PagesPanel()
    {
        InitializeComponent();
        _ = new PageDrag(Thumbs, () => Cells, Selected, (pages, before) => MoveTo(pages, before));
        foreach (var size in PaperSize.All) Paper.Items.Add(size.Name);
        Paper.Items.Add(Loc.T("Custom size"));
        Paper.SelectedIndex = 0;
    }

    private List<PageCell> Cells => Thumbs.ItemsSource as List<PageCell> ?? [];

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        _pages = PageNumbers();
        _dpr = VisualTreeHelper.GetDpi(this).DpiScaleX;
        Build();
        Arm();
    }

    protected override void OnDetach()
    {
        CloseOrganize();
        Disarm();
        Tab!.Changed -= Tab_Changed;
        foreach (var cell in Cells) cell.Release();
        Thumbs.ItemsSource = null;
    }

    private void Organize_Click(object sender, RoutedEventArgs e)
    {
        if (_organize is not null) return;
        _organize = new OrganizeView();
        _organize.Closed += Organize_Closed;
        _organize.Attach(Tab!, Viewer!, Host!);
        Host!.HoldStage(_organize);
    }

    private void Organize_Closed(object? sender, EventArgs e) => CloseOrganize();

    private void CloseOrganize()
    {
        if (_organize is not { } view) return;
        _organize = null;
        view.Closed -= Organize_Closed;
        Host!.HoldStage(null);
        view.Detach();
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        var select = _reselect;
        _reselect = null;
        Build(select);
        // The box holds a page index and display points, which an edit to the page list or to its page's shape moves.
        int[] pages = PageNumbers();
        if (!pages.SequenceEqual(_pages) || _crop?.Box is { } box && BoxSpace(box.Page) != _boxSpace) _crop?.Clear();
        _pages = pages;
    }

    private (PdfRect, PdfRect, int, double) _boxSpace;

    private (PdfRect, PdfRect, int, double) BoxSpace(int index)
    {
        var page = Tab!.Document.Pages[index];
        return (page.MediaBox, page.CropBox, page.Rotate, page.UserUnit);
    }

    private int[] _pages = [];

    private int[] PageNumbers() => [.. Tab!.Document.Pages.Select(p => p.Reference.Number)];

    private void Build(IEnumerable<int>? select = null)
    {
        var document = Tab!.Document;
        var labels = PdfPageLabels.Labels(document);
        var cells = new List<PageCell>(document.Pages.Count);
        for (int i = 0; i < document.Pages.Count; i++)
        {
            var shown = new PageGeometry(document.Pages[i]);
            double scale = Math.Min(BoxWidth / Math.Max(shown.Width, 1), BoxHeight / Math.Max(shown.Height, 1));
            cells.Add(new PageCell(i, labels[i], Math.Max(Math.Round(shown.Width * scale), 4), Math.Max(Math.Round(shown.Height * scale), 4), scale));
        }
        _syncing = true;
        Thumbs.ItemsSource = cells;
        foreach (int page in select ?? [])
        {
            if (page >= 0 && page < cells.Count) Thumbs.SelectedItems.Add(cells[page]);
        }
        _syncing = false;
        if (select is not null && Thumbs.SelectedItems.Count > 0) Thumbs.ScrollIntoView(Thumbs.SelectedItems[0]);
        Dispatcher.BeginInvoke(LoadVisible, DispatcherPriority.Loaded);
        Refresh();
    }

    private List<int> Selected() => [.. Thumbs.SelectedItems.Cast<PageCell>().Select(c => c.Index).Order()];

    // Pages a job covers: the selection, else every page.
    private List<int> SelectedOrAll()
    {
        var pages = Selected();
        return pages.Count > 0 ? pages : [.. Enumerable.Range(0, Cells.Count)];
    }

    private void Thumbs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing) return;
        _boxSelected = false;
        if (Thumbs.SelectedItems.Count == 1 && Viewer is { } viewer && Thumbs.SelectedItem is PageCell cell && viewer.PageIndex != cell.Index) viewer.GoToPage(cell.Index);
        Refresh();
    }

    private void Thumbs_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != System.Windows.Input.Key.Delete || Thumbs.SelectedItems.Count == 0) return;
        Remove_Click(sender, e);
        e.Handled = true;
    }

    private void Fields_Changed(object sender, TextChangedEventArgs e) => Refresh();

    // The bar, the count and the hints follow the selection; the pinned action follows the open section.
    private void Refresh()
    {
        if (Tab is null) return;
        var pages = Selected();
        int total = Cells.Count;
        bool any = pages.Count > 0;
        TurnLeft.IsEnabled = TurnRight.IsEnabled = Copy.IsEnabled = Extract.IsEnabled = Remove.IsEnabled = any;
        Earlier.IsEnabled = PageEdits.CanNudge(pages, -1, total);
        Later.IsEnabled = PageEdits.CanNudge(pages, 1, total);
        Replace.IsEnabled = any;
        SignedRow.Visibility = Tab.Document.IsSigned ? Visibility.Visible : Visibility.Collapsed;
        Summary.Text = any ? Loc.T("{0} of {1} selected", pages.Count, total) : Loc.Plural(total, "{0} page", "{0} pages", total);
        RefreshHints(pages);
        RaiseActionChanged();
    }

    // Tiles in view and one row either side get a picture; the rest let theirs go.
    private void LoadVisible()
    {
        if (Tab?.Renderer is not WindowsPageRenderer renderer || Scroller() is not { } scroll) return;
        int columns = Math.Max(1, (int)(scroll.ViewportWidth / ColumnStep));
        int first = Math.Max(0, (int)(scroll.VerticalOffset / RowStep) - 1) * columns;
        int last = ((int)((scroll.VerticalOffset + scroll.ViewportHeight) / RowStep) + 2) * columns;
        var cells = Cells;
        for (int i = 0; i < cells.Count; i++)
        {
            if (i >= first && i < last) _ = cells[i].LoadAsync(renderer, cells[i].Scale * 72 * _dpr);
            else cells[i].Release();
        }
    }

    private ScrollViewer? Scroller() => PageDrag.Descendant<ScrollViewer>(Thumbs);

    private void Thumbs_ScrollChanged(object sender, ScrollChangedEventArgs e) => LoadVisible();

    private void Thumbs_SizeChanged(object sender, SizeChangedEventArgs e) => LoadVisible();
}
