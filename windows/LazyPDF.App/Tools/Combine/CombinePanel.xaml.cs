using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Combine;

/// <summary>Puts this file and others into one, with the pages and the order the person picks, or cuts this file into parts.</summary>
public partial class CombinePanel : ToolPanel
{
    private const string EntryFormat = "LazyPDF.CombineEntry";

    // Each document keeps its own list, so a look at another tab does not lose the files that were picked.
    private readonly ConditionalWeakTable<DocumentTab, ObservableCollection<CombineEntry>> _lists = [];
    private ObservableCollection<CombineEntry> _entries = [];
    private string? _folder;
    private Point _dragStart;
    private CombineEntry? _dragEntry;
    private CombineEntry? _marked;

    public CombinePanel()
    {
        InitializeComponent();
    }

    private bool Splitting => ModeSplit.IsChecked == true;

    private SplitBy Kind => (SplitBy)SplitKind.SelectedIndex;

    public override ToolAction? Action => Splitting
        ? new(Loc.T("Split file"), "", () => Tab is { PageCount: > 1 } && CombineJob.TryAmount(Kind, Amount.Text, out _), SplitAsync)
        : new(Loc.T("Combine files"), "", () => _entries.Count > 1, CombineAsync);

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        if (!_lists.TryGetValue(Tab, out var list))
        {
            list = [new CombineEntry(Tab.Title, Tab.PageCount, null)];
            list.CollectionChanged += (_, _) => RaiseActionChanged();
            _lists.Add(Tab, list);
        }
        _entries = list;
        Files.ItemsSource = list;
        // The file may have lost or gained pages while another tab was shown.
        foreach (var entry in list.Where(x => x.Document is null)) entry.Pages = Tab.PageCount;
        Refresh();
    }

    protected override void OnDetach() => Tab!.Changed -= Tab_Changed;

    private void Tab_Changed(object? sender, EventArgs e)
    {
        foreach (var entry in _entries.Where(x => x.Document is null)) entry.Pages = Tab!.PageCount;
        Refresh();
    }

    private void Refresh()
    {
        if (Tab is null) return;
        SignedRow.Visibility = Tab.Document.IsSigned ? Visibility.Visible : Visibility.Collapsed;
        CombineView.Visibility = Splitting ? Visibility.Collapsed : Visibility.Visible;
        SplitView.Visibility = Splitting ? Visibility.Visible : Visibility.Collapsed;
        AmountView.Visibility = Kind == SplitBy.Bookmarks ? Visibility.Collapsed : Visibility.Visible;
        AmountLabel.Text = Kind == SplitBy.Size ? Loc.T("Megabytes per part") : Loc.T("Pages per part");
        SplitHint.Text = Kind == SplitBy.Bookmarks ? BookmarkHint(Tab.Document)
            : Tab.PageCount < 2 ? Loc.T("A file of one page cannot be split.") : "";
        SplitHint.Visibility = SplitHint.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        RaiseActionChanged();
    }

    private static string BookmarkHint(PdfDocument document)
    {
        int parts = CombineJob.BookmarkParts(document);
        return Loc.Plural(parts, "The bookmarks make {0} part.", "The bookmarks make {0} parts.", parts);
    }

    private void Mode_Checked(object sender, RoutedEventArgs e) => Refresh();

    private void SplitKind_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Tab is null) return;
        Amount.Text = Kind == SplitBy.Size ? "5" : "10";
        Refresh();
    }

    private void Amount_TextChanged(object sender, TextChangedEventArgs e) => RaiseActionChanged();

    private static CombineEntry Entry(object sender) => (CombineEntry)((FrameworkElement)sender).DataContext;

    private void EntryUp_Click(object sender, RoutedEventArgs e)
    {
        int at = _entries.IndexOf(Entry(sender));
        if (at > 0) _entries.Move(at, at - 1);
    }

    private void EntryDown_Click(object sender, RoutedEventArgs e)
    {
        int at = _entries.IndexOf(Entry(sender));
        if (at < _entries.Count - 1) _entries.Move(at, at + 1);
    }

    private void EntryRemove_Click(object sender, RoutedEventArgs e) => _entries.Remove(Entry(sender));

    private async void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("PDF files") + "|*.pdf", Multiselect = true, CheckFileExists = true };
        if (dialog.ShowDialog() == true) await AddAsync(Host, _entries, dialog.FileNames);
    }

    private void Card_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _dragStart = e.GetPosition(null);
        _dragEntry = _entries.Count > 1 && e.OriginalSource is DependencyObject source && !InsideEditor(source) ? Entry(sender) : null;
    }

    private static bool InsideEditor(DependencyObject node)
    {
        for (; node is not null; node = VisualTreeHelper.GetParent(node) ?? LogicalTreeHelper.GetParent(node))
        {
            if (node is TextBox or Button) return true;
        }
        return false;
    }

    private void Card_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _dragEntry is not { } entry) return;
        var now = e.GetPosition(null);
        if (Math.Abs(now.X - _dragStart.X) < SystemParameters.MinimumHorizontalDragDistance
            && Math.Abs(now.Y - _dragStart.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragEntry = null;
        DragDrop.DoDragDrop((DependencyObject)sender, new DataObject(EntryFormat, entry), DragDropEffects.Move);
        Mark(null, false);
    }

    private void Card_DragLeave(object sender, DragEventArgs e) => Mark(null, false);

    private void Card_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(EntryFormat) is not CombineEntry moved) return;
        e.Handled = true;
        Mark(null, false);
        var card = (FrameworkElement)sender;
        int from = _entries.IndexOf(moved);
        int to = TargetIndex(from, _entries.IndexOf(Entry(sender)), e.GetPosition(card).Y >= card.ActualHeight / 2);
        if (from >= 0 && to != from) _entries.Move(from, to);
    }

    // Where the moved entry ends up when it is dropped on the upper or lower half of the entry at over.
    internal static int TargetIndex(int from, int over, bool lowerHalf)
    {
        int at = over + (lowerHalf ? 1 : 0);
        return from < at ? at - 1 : at;
    }

    private void Mark(CombineEntry? entry, bool after)
    {
        if (_marked is not null && !ReferenceEquals(_marked, entry)) _marked.DropBefore = _marked.DropAfter = false;
        _marked = entry;
        if (entry is null) return;
        entry.DropBefore = !after;
        entry.DropAfter = after;
    }

    // The panel handles PreviewDragOver first, so the card's own DragOver never runs and the line is set from here.
    private void MarkUnder(DragEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject source || ItemsControl.ContainerFromElement(Files, source) is not { } holder
            || VisualTreeHelper.GetChild(holder, 0) is not FrameworkElement card)
        {
            Mark(null, false);
            return;
        }
        var entry = Entry(card);
        Mark(ReferenceEquals(entry, e.Data.GetData(EntryFormat)) ? null : entry, e.GetPosition(card).Y >= card.ActualHeight / 2);
    }

    private void Panel_DragOver(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(EntryFormat))
        {
            e.Effects = DragDropEffects.Move;
            e.Handled = true;
            MarkUnder(e);
            return;
        }
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    private async void Panel_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        var pdfs = paths.Where(p => string.Equals(System.IO.Path.GetExtension(p), ".pdf", StringComparison.OrdinalIgnoreCase)).ToList();
        bool opened = await AddAsync(Host, _entries, pdfs);
        int skipped = paths.Count(p => !pdfs.Contains(p) && !System.IO.Directory.Exists(p));
        if (opened && skipped > 0)
            Host?.ShowNotice(Loc.T("Not a PDF"), Loc.Plural(skipped, "{0} dropped file is not a PDF and was left out.", "{0} dropped files are not PDFs and were left out.", skipped));
    }

    // False when a file could not be opened or has no pages; what happened is already on screen.
    internal static async Task<bool> AddAsync(IToolHost? host, ICollection<CombineEntry> list, IEnumerable<string> paths)
    {
        if (host is null) return false;
        bool all = true;
        foreach (string path in paths)
        {
            string name = System.IO.Path.GetFileName(path);
            if (await SourceFile.OpenAsync(host, path) is not { } document) all = false;
            else if (document.Pages.Count == 0)
            {
                host.ShowNotice(Loc.T("Nothing to add"), Loc.T("{0} has no pages, so it was left out.", name));
                all = false;
            }
            else list.Add(new CombineEntry(name, document.Pages.Count, document));
        }
        return all;
    }
}
