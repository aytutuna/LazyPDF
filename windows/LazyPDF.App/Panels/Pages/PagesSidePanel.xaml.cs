using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Panels.Pages;

/// <summary>A list that can move its shift-click anchor, which setting the selection in code does not do in Extended mode.</summary>
public sealed class ThumbList : ListBox
{
    // The anchor has to be a row that exists, and a virtualized list makes it only once it is scrolled to.
    public void Anchor(object item)
    {
        UpdateLayout();
        if (ItemContainerGenerator.ContainerFromItem(item) is not null) AnchorItem = item;
    }
}

/// <summary>Every page as a small picture, the page in view marked; a click goes to the page; Ctrl or Shift picks more, to turn, delete or extract. The list shows only the rows in view.</summary>
public partial class PagesSidePanel : ToolPanel
{
    private readonly DispatcherTimer _resize = new() { Interval = TimeSpan.FromMilliseconds(150) };
    private bool _syncing;
    private PageThumb? _downThumb;
    private PageThumb? _pressed;
    private Point _pressAt;
    private bool _keptSelection;
    private PageThumb? _marked;
    private bool _after;
    private IEnumerable<int>? _reselect;

    public PagesSidePanel()
    {
        InitializeComponent();
        _syncing = true;
        ThumbSize.Value = AppPreferencesStore.Load().ThumbnailWidth;
        _syncing = false;
        _resize.Tick += (_, _) => Resized();
    }

    private double BoxWidth => ThumbSize.Value;

    private double BoxHeight => ThumbSize.Value * 190 / 132;

    // The pictures are drawn again at the new size once the slider stops, not at every step of it.
    private void ThumbSize_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_syncing) return;
        _resize.Stop();
        _resize.Start();
    }

    internal void Resized()
    {
        _resize.Stop();
        double width = ThumbSize.Value;
        AppPreferencesStore.Update(p => p.ThumbnailWidth = width);
        if (Tab is not null) Build();
    }

    protected override void OnAttach()
    {
        Viewer!.PageChanged += Viewer_PageChanged;
        Tab!.Changed += Tab_Changed;
        Build();
    }

    protected override void OnDetach()
    {
        _resize.Stop();
        Viewer!.PageChanged -= Viewer_PageChanged;
        Tab!.Changed -= Tab_Changed;
        Thumbs.ItemsSource = null;
    }

    private void Build()
    {
        var tab = Tab!;
        var viewer = Viewer!;
        var renderer = tab.Renderer as WindowsPageRenderer;
        double dpr = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var items = new List<PageThumb>(viewer.PageCount);
        for (int i = 0; i < viewer.PageCount; i++)
        {
            var size = viewer.PageSize(i);
            double scale = Math.Min(BoxWidth / Math.Max(size.Width, 1), BoxHeight / Math.Max(size.Height, 1));
            items.Add(new PageThumb(i, viewer.PageLabel(i), Math.Round(size.Width * scale), Math.Round(size.Height * scale), scale * 72 * dpr, tab.Document.Pages[i].Reference.Number, renderer));
        }
        // A slot keeps its old picture until the new one is drawn, but only when the same page is still in it.
        if (Thumbs.ItemsSource is List<PageThumb> old && old.Count == items.Count)
            for (int i = 0; i < items.Count; i++) items[i].Inherit(old[i]);
        var select = _reselect;
        _reselect = null;
        _syncing = true;
        Thumbs.ItemsSource = items;
        if (select is not null)
            foreach (int page in select)
                if (page >= 0 && page < items.Count) Thumbs.SelectedItems.Add(items[page]);
        _syncing = false;
        if (Thumbs.SelectedItem is { } kept && select is not null) Thumbs.ScrollIntoView(kept);
        else Mark();
    }

    // The page in view gets the ring and is scrolled into the list.
    private void Mark()
    {
        if (Viewer is not { } viewer || Thumbs.Items.Count == 0 || Thumbs.SelectedItems.Count > 1) return;
        int page = Math.Clamp(viewer.PageIndex, 0, Thumbs.Items.Count - 1);
        if (Thumbs.SelectedIndex == page) return;
        _syncing = true;
        Thumbs.SelectedIndex = page;
        _syncing = false;
        Thumbs.ScrollIntoView(Thumbs.SelectedItem);
        Thumbs.Anchor(Thumbs.SelectedItem);
    }

    private void Viewer_PageChanged(object? sender, EventArgs e) => Mark();

    private void Tab_Changed(object? sender, EventArgs e) => Build();

    private void Thumbs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || Thumbs.SelectedItems.Count != 1 || Viewer is not { } viewer) return;
        if (viewer.PageIndex != Thumbs.SelectedIndex) viewer.GoToPage(Thumbs.SelectedIndex);
    }

    // Clicking the row already selected raises no SelectionChanged, so it is handled here.
    private void Thumbs_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var item = ItemsControl.ContainerFromElement(Thumbs, (DependencyObject)e.OriginalSource) as ListBoxItem;
        _downThumb = item is { IsSelected: true } && Keyboard.Modifiers == ModifierKeys.None && Thumbs.SelectedItems.Count == 1 ? item.DataContext as PageThumb : null;
        _pressed = item?.DataContext as PageThumb;
        _pressAt = e.GetPosition(Thumbs);
        _keptSelection = false;
        // Pressing on one of several selected pages must not drop the others yet: it may be the start of a drag.
        if (item is not { IsSelected: true } || Keyboard.Modifiers != ModifierKeys.None || Thumbs.SelectedItems.Count < 2) return;
        _keptSelection = true;
        Thumbs.Focus();
        e.Handled = true;
    }

    private void Thumbs_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        var item = ItemsControl.ContainerFromElement(Thumbs, (DependencyObject)e.OriginalSource) as ListBoxItem;
        if (_downThumb is { } thumb && item?.DataContext == thumb) Viewer?.GoToPage(thumb.Index);
        if (_keptSelection && _pressed is { } only) Thumbs.SelectedItem = only;
        _downThumb = null;
        _pressed = null;
        _keptSelection = false;
    }

    private void Thumbs_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _pressed is not { } thumb) return;
        var moved = e.GetPosition(Thumbs) - _pressAt;
        if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _pressed = null;
        _downThumb = null;
        _keptSelection = false;
        if (!Thumbs.SelectedItems.Contains(thumb)) Thumbs.SelectedItem = thumb;
        DragDrop.DoDragDrop(Thumbs, new DataObject(PageDrag.Format, Selected()), DragDropEffects.Move);
        Unmark();
    }

    private void Thumbs_DragOver(object sender, DragEventArgs e)
    {
        e.Handled = true;
        if (!e.Data.GetDataPresent(PageDrag.Format))
        {
            e.Effects = DragDropEffects.None;
            return;
        }
        e.Effects = DragDropEffects.Move;
        Unmark();
        var at = e.GetPosition(Thumbs);
        if (RowAt(at) is { } row)
        {
            _marked = (PageThumb)row.DataContext;
            _after = e.GetPosition(row).Y >= row.ActualHeight / 2;
        }
        else if (Thumbs.Items.Count > 0)
        {
            _marked = (PageThumb)Thumbs.Items[^1];
            _after = true;
        }
        if (_marked is not null)
        {
            if (_after) _marked.DropAfter = true;
            else _marked.DropBefore = true;
        }
        if (PageDrag.Descendant<ScrollViewer>(Thumbs) is not { } scroll) return;
        if (at.Y < 28) scroll.ScrollToVerticalOffset(scroll.VerticalOffset - 24);
        else if (at.Y > Thumbs.ActualHeight - 28) scroll.ScrollToVerticalOffset(scroll.VerticalOffset + 24);
    }

    // The gap between two rows belongs to the row above it.
    private ListBoxItem? RowAt(Point at)
    {
        foreach (double nudge in new[] { 0, -4, 4 })
        {
            if (Thumbs.InputHitTest(new Point(at.X, at.Y + nudge)) is DependencyObject hit
                && ItemsControl.ContainerFromElement(Thumbs, hit) is ListBoxItem row) return row;
        }
        return null;
    }

    private void Thumbs_DragLeave(object sender, DragEventArgs e) => Unmark();

    private void Thumbs_Drop(object sender, DragEventArgs e)
    {
        int before = _marked is null ? Thumbs.Items.Count : _after ? _marked.Index + 1 : _marked.Index;
        Unmark();
        if (e.Data.GetData(PageDrag.Format) is List<int> pages && pages.Count > 0) MovePages(pages, before);
        e.Handled = true;
    }

    private void Unmark()
    {
        if (_marked is null) return;
        _marked.DropBefore = false;
        _marked.DropAfter = false;
        _marked = null;
    }

    internal void MovePages(List<int> pages, int before)
    {
        if (pages.Count == 0 || Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => Move(tab, host, pages, before))) return;
        Move(tab, host, pages, before);
    }

    private void Move(DocumentTab tab, IToolHost host, List<int> pages, int before)
    {
        if (!Still(tab, pages)) return;
        pages.Sort();
        // Pages that already stand together at that spot would only get a step that changes nothing.
        if (pages[^1] - pages[0] == pages.Count - 1 && before >= pages[0] && before <= pages[^1] + 1) return;
        _reselect = Tools.Pages.PageEdits.MovedTo(pages, before).ToList();
        try
        {
            PageJobs.Apply(tab, host, Loc.T("Move pages"), d => PageOperations.Move(d, pages, before),
                           Loc.Plural(pages.Count, "{0} page moved", "{0} pages moved", pages.Count));
        }
        finally
        {
            _reselect = null;
        }
    }

    private void Thumb_Unloaded(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is PageThumb thumb) thumb.Release();
    }

    private List<int> Selected() => [.. Thumbs.SelectedItems.Cast<PageThumb>().Select(t => t.Index).Order()];

    private void Thumbs_PreviewMouseRightButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (ItemsControl.ContainerFromElement(Thumbs, (DependencyObject)e.OriginalSource) is ListBoxItem { IsSelected: false } item)
            Thumbs.SelectedItem = item.DataContext;
    }

    private void Thumbs_PreviewKeyDown(object sender, KeyEventArgs e) => e.Handled = Press(e.Key, Keyboard.Modifiers);

    internal bool Press(Key key, ModifierKeys modifiers)
    {
        if (key != Key.Delete || modifiers != ModifierKeys.None || Thumbs.SelectedItems.Count == 0) return false;
        Delete();
        return true;
    }

    private void TurnLeft_Click(object sender, RoutedEventArgs e) => Turn(-90);

    private void TurnRight_Click(object sender, RoutedEventArgs e) => Turn(90);

    private void Delete_Click(object sender, RoutedEventArgs e) => Delete();

    // Null when the file may not be changed now; a refusal is shown with its reason.
    private (DocumentTab Tab, IToolHost Host)? Editable()
    {
        if (Tab is not { } tab || Host is not { } host || MarkWork.Running) return null;
        if (Clearance.Refusal(tab.Document) is { } problem)
        {
            host.ShowProblem(problem);
            return null;
        }
        return (tab, host);
    }

    // For a change held back by the notice: the same tab is open and still has the pages that were picked.
    private bool Still(DocumentTab tab, List<int> pages) =>
        ReferenceEquals(Tab, tab) && !MarkWork.Running && Clearance.Refusal(tab.Document) is null && pages.All(p => p < Thumbs.Items.Count);

    internal void Turn(int degrees)
    {
        var pages = Selected();
        if (pages.Count == 0 || Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => Rotate(tab, host, pages, degrees))) return;
        Rotate(tab, host, pages, degrees);
    }

    private void Rotate(DocumentTab tab, IToolHost host, List<int> pages, int degrees)
    {
        if (!Still(tab, pages)) return;
        _reselect = pages;
        try
        {
            PageJobs.Apply(tab, host, Loc.T("Rotate pages"), d => PageOperations.Rotate(d, pages, degrees),
                           Loc.Plural(pages.Count, "{0} page rotated", "{0} pages rotated", pages.Count));
        }
        finally
        {
            _reselect = null;
        }
    }

    private void Delete()
    {
        var pages = Selected();
        if (pages.Count == 0 || Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => Remove(tab, host, pages))) return;
        Remove(tab, host, pages);
    }

    private void Remove(DocumentTab tab, IToolHost host, List<int> pages)
    {
        if (!Still(tab, pages)) return;
        if (pages.Count == Thumbs.Items.Count)
        {
            host.ShowProblem(new Problem(Loc.T("Cannot delete every page"), Loc.T("A file needs at least one page. Leave one page out of the selection.")));
            return;
        }
        PageJobs.Delete(tab, host, Loc.T("Delete pages"), pages, Loc.Plural(pages.Count, "{0} page deleted", "{0} pages deleted", pages.Count));
    }

    private async void Extract_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        if (Tab is not { } tab || Host is not { } host || pages.Count == 0) return;
        var failed = new Problem(Loc.T("Pages not extracted"), Loc.T("The pages could not be copied into a new file. Try fewer pages."));
        if (await PageJobs.CopyOutAsync(tab, host, pages, Loc.T("Extracting pages"), failed) is not { } bytes) return;
        if (!await host.OpenNewAsync(bytes, Loc.T("{0} extract.pdf", System.IO.Path.GetFileNameWithoutExtension(tab.Title)))) return;
        host.SetStatus(Loc.Plural(pages.Count, "{0} page extracted", "{0} pages extracted", pages.Count));
        CopyRules.NoteUnprotected(tab.Document, host);
    }

    private void Blank_Click(object sender, RoutedEventArgs e) => InsertBlank();

    internal void InsertBlank()
    {
        var pages = Selected();
        if (Editable() is not var (tab, host) || MarkWork.Cautioned(tab, host, () => AddBlank(tab, host, pages))) return;
        AddBlank(tab, host, pages);
    }

    private void AddBlank(DocumentTab tab, IToolHost host, List<int> pages)
    {
        if (!Still(tab, pages)) return;
        int at = Tools.Pages.PageEdits.InsertAt(InsertPlace.AfterSelection, pages, Thumbs.Items.Count);
        _reselect = [at];
        try
        {
            PageJobs.Apply(tab, host, Loc.T("Insert blank page"), d =>
            {
                var (width, height) = Tools.Pages.PageEdits.NeighbourSize(d, at);
                PageOperations.InsertBlank(d, at, width, height);
            }, Loc.T("Blank page added."));
        }
        finally
        {
            _reselect = null;
        }
    }

    private void FromFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("PDF files") + "|*.pdf", CheckFileExists = true, Multiselect = true };
        if (dialog.ShowDialog() == true) _ = InsertFilesAsync(dialog.FileNames);
    }

    internal async Task InsertFilesAsync(IEnumerable<string> paths)
    {
        var pages = Selected();
        if (Editable() is not var (tab, host)) return;
        if (MarkWork.Cautioned(tab, host, () => _ = AddFilesAsync(tab, host, paths, pages))) return;
        await AddFilesAsync(tab, host, paths, pages);
    }

    private async Task AddFilesAsync(DocumentTab tab, IToolHost host, IEnumerable<string> paths, List<int> pages)
    {
        if (!Still(tab, pages)) return;
        int at = Tools.Pages.PageEdits.InsertAt(InsertPlace.AfterSelection, pages, Thumbs.Items.Count);
        int added = await PageJobs.InsertFilesAsync(tab, host, paths, at);
        if (added > 0) Select(Enumerable.Range(at, added));
    }

    private void Select(IEnumerable<int> pages)
    {
        _syncing = true;
        Thumbs.SelectedItems.Clear();
        foreach (int page in pages)
            if (page >= 0 && page < Thumbs.Items.Count) Thumbs.SelectedItems.Add(Thumbs.Items[page]);
        _syncing = false;
        if (Thumbs.SelectedItem is { } kept) Thumbs.ScrollIntoView(kept);
    }
}
