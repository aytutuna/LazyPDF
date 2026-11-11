using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>
/// The pages of the document tab as a large grid on the stage, held there by <see cref="IToolHost.HoldStage"/>:
/// select, drag into a new order, rotate, delete, copy between tabs and drop files in. Each action is one commit.
/// </summary>
public sealed partial class OrganizeView : ToolPanel
{
    // The page picture sits in a box this much taller than wide; the tile adds room for the label and the selection ring.
    private const double BoxRatio = 1.4;
    private const double TilePadding = 32;
    private const double LabelHeight = 30;

    private readonly DispatcherTimer _sharpen;
    private List<(double Width, double Height)> _sizes = [];
    private bool _syncing;

    public OrganizeView()
    {
        InitializeComponent();
        _ = new PageDrag(Thumbs, () => Cells, Selected, (pages, before) => MoveTo(pages, before), (paths, before) => _ = InsertFilesAsync(paths, before));
        // The pictures are made again at the new size once the slider stops, not at every step of it.
        _sharpen = new DispatcherTimer(TimeSpan.FromMilliseconds(200), DispatcherPriority.Background, Sharpen_Tick, Dispatcher) { IsEnabled = false };
        IsEnabledChanged += View_IsEnabledChanged;
    }

    /// <summary>Raised when the person is done and the stage should go back to the viewer.</summary>
    public event EventHandler? Closed;

    private List<PageCell> Cells => Thumbs.ItemsSource as List<PageCell> ?? [];

    private double BoxWidth => TileSize.Value;

    private double BoxHeight => TileSize.Value * BoxRatio;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Build();
        Refresh();
        Dispatcher.BeginInvoke(() => Thumbs.Focus(), DispatcherPriority.Loaded);
    }

    protected override void OnDetach()
    {
        _sharpen.Stop();
        Tab!.Changed -= Tab_Changed;
        foreach (var cell in Cells) cell.Release();
        Thumbs.ItemsSource = null;
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        bool hadFocus = Thumbs.IsKeyboardFocusWithin;
        Build();
        Refresh();
        if (hadFocus) Dispatcher.BeginInvoke(FocusSelected, DispatcherPriority.Loaded);
    }

    // Build replaces the items, which drops the tile that had the keyboard focus.
    private void FocusSelected()
    {
        if (Tab is null) return;
        if (Thumbs.SelectedItems.Count > 0)
        {
            int first = Thumbs.Items.IndexOf(Thumbs.SelectedItems[0]);
            Thumbs.ScrollIntoView(Thumbs.SelectedItems[0]);
            if (Thumbs.ItemContainerGenerator.ContainerFromIndex(first) is ListBoxItem item && item.Focus()) return;
        }
        Thumbs.Focus();
    }

    // The window disables its workspace while a job runs, which takes the keyboard focus with it and does not give it back.
    private void View_IsEnabledChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsEnabled && Tab is not null) Dispatcher.BeginInvoke(() =>
        {
            if (!IsKeyboardFocusWithin) Thumbs.Focus();
        }, DispatcherPriority.Input);
    }

    private void Build()
    {
        foreach (var cell in Cells) cell.Release();
        var document = Tab!.Document;
        var labels = PdfPageLabels.Labels(document);
        _sizes = [.. document.Pages.Select(page =>
        {
            var shown = new PageGeometry(page);
            return (shown.Width, shown.Height);
        })];
        var cells = new List<PageCell>(_sizes.Count);
        for (int i = 0; i < _sizes.Count; i++)
        {
            var (width, height, scale) = Fit(i);
            cells.Add(new PageCell(i, labels[i], width, height, scale));
        }
        Thumbs.ItemsSource = cells;
        Dispatcher.BeginInvoke(Lay, DispatcherPriority.Loaded);
    }

    private (double Width, double Height, double Scale) Fit(int page)
    {
        var (width, height) = _sizes[page];
        double scale = Math.Min(BoxWidth / Math.Max(width, 1), BoxHeight / Math.Max(height, 1));
        return (Math.Max(Math.Round(width * scale), 4), Math.Max(Math.Round(height * scale), 4), scale);
    }

    // The grid's cells are as large as the picture box plus room around it; the panel exists once the list has been laid out.
    private void Lay()
    {
        if (PageDrag.Descendant<TilePanel>(Thumbs) is { } tiles)
        {
            tiles.CellWidth = BoxWidth + TilePadding;
            tiles.CellHeight = BoxHeight + LabelHeight;
        }
        LoadVisible();
    }

    private void TileSize_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (Tab is null) return;
        var cells = Cells;
        for (int i = 0; i < cells.Count; i++)
        {
            var (width, height, scale) = Fit(i);
            cells[i].Refit(width, height, scale);
        }
        Lay();
        _sharpen.Stop();
        _sharpen.Start();
    }

    private void Sharpen_Tick(object? sender, EventArgs e)
    {
        _sharpen.Stop();
        foreach (var cell in Cells) cell.Release();
        LoadVisible();
    }

    // Tiles in view and a row either side get a picture; the rest let theirs go.
    private void LoadVisible()
    {
        if (Tab?.Renderer is not WindowsPageRenderer renderer || PageDrag.Descendant<TilePanel>(Thumbs) is not { } tiles) return;
        var (first, last) = tiles.Window(1);
        double dpr = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var cells = Cells;
        for (int i = 0; i < cells.Count; i++)
        {
            if (i >= first && i <= last) _ = cells[i].LoadAsync(renderer, cells[i].Scale * 72 * dpr);
            else cells[i].Release();
        }
    }

    private void Thumbs_ScrollChanged(object sender, ScrollChangedEventArgs e) => LoadVisible();

    private void Thumbs_SizeChanged(object sender, SizeChangedEventArgs e) => LoadVisible();

    private List<int> Selected() => [.. Thumbs.SelectedItems.Cast<PageCell>().Select(c => c.Index).Order()];

    private void Select(IEnumerable<int> pages)
    {
        var cells = Cells;
        _syncing = true;
        Thumbs.SelectedItems.Clear();
        foreach (int page in pages)
        {
            if (page >= 0 && page < cells.Count) Thumbs.SelectedItems.Add(cells[page]);
        }
        _syncing = false;
        if (Thumbs.SelectedItems.Count > 0) Thumbs.ScrollIntoView(Thumbs.SelectedItems[0]);
        Refresh();
    }

    // The tab can have been left while a job ran; its pages are then not on screen to select.
    private void Reselect(DocumentTab tab, IEnumerable<int> pages)
    {
        if (ReferenceEquals(Tab, tab)) Select(pages);
    }

    private void Thumbs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncing) Refresh();
    }

    private void Refresh()
    {
        if (Tab is null) return;
        int selected = Thumbs.SelectedItems.Count;
        int total = Cells.Count;
        bool any = selected > 0;
        TurnLeft.IsEnabled = TurnRight.IsEnabled = Remove.IsEnabled = Duplicate.IsEnabled = Extract.IsEnabled = Cut.IsEnabled = Copy.IsEnabled = any;
        Paste.IsEnabled = PageClipboard.Count > 0;
        SignedRow.Visibility = Tab.Document.IsSigned ? Visibility.Visible : Visibility.Collapsed;
        Summary.Text = any ? Loc.T("{0} of {1} selected", selected, total) : Loc.Plural(total, "{0} page", "{0} pages", total);
    }

    private void View_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!Place.IsDropDownOpen) e.Handled = Press(e.Key, Keyboard.Modifiers);
    }

    // Files dropped on the bar or the footer go to the end, as the grid has no gap there to mark.
    private void View_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void View_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } paths) _ = InsertFilesAsync(paths, Cells.Count);
        e.Handled = true;
    }

    // False when the key is none of the view's, so the list and the window go on with it.
    internal bool Press(Key key, ModifierKeys modifiers)
    {
        bool any = Thumbs.SelectedItems.Count > 0;
        switch (key)
        {
            case Key.Delete when modifiers == ModifierKeys.None && any: Remove_Click(this, new RoutedEventArgs()); return true;
            case Key.A when modifiers == ModifierKeys.Control: Thumbs.SelectAll(); return true;
            case Key.X when modifiers == ModifierKeys.Control && any: Cut_Click(this, new RoutedEventArgs()); return true;
            case Key.C when modifiers == ModifierKeys.Control && any: Copy_Click(this, new RoutedEventArgs()); return true;
            case Key.V when modifiers == ModifierKeys.Control: Paste_Click(this, new RoutedEventArgs()); return true;
            case Key.Left or Key.Right when modifiers == ModifierKeys.Control && any: Nudge(key == Key.Left ? -1 : 1); return true;
            case Key.Left or Key.Right when modifiers == (ModifierKeys.Control | ModifierKeys.Shift) && any: Turn(Selected(), key == Key.Left ? -90 : 90); return true;
            case Key.D when modifiers == ModifierKeys.Control && any: Duplicate_Click(this, new RoutedEventArgs()); return true;
            case Key.Escape when modifiers == ModifierKeys.None: Done_Click(this, new RoutedEventArgs()); return true;
            default: return false;
        }
    }

    private void Thumbs_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (Keyboard.Modifiers != ModifierKeys.None || e.OriginalSource is not DependencyObject source || PageDrag.Ancestor<ButtonBase>(source) is not null
            || ItemsControl.ContainerFromElement(Thumbs, source) is not ListBoxItem { DataContext: PageCell cell }) return;
        Viewer?.GoToPage(cell.Index);
        Done_Click(sender, e);
    }

    private void Done_Click(object sender, RoutedEventArgs e) => Closed?.Invoke(this, EventArgs.Empty);
}
