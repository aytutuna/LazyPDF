using System.Collections.ObjectModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Combine;

/// <summary>Puts this file and others into one, with the pages and the order the person picks, or cuts this file into parts.</summary>
public partial class CombinePanel : ToolPanel
{
    // Each document keeps its own list, so a look at another tab does not lose the files that were picked.
    private readonly ConditionalWeakTable<DocumentTab, ObservableCollection<CombineEntry>> _lists = [];
    private ObservableCollection<CombineEntry> _entries = [];
    private string? _folder;

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
        if (dialog.ShowDialog() == true) await AddAsync(dialog.FileNames);
    }

    private void Panel_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private async void Panel_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        await AddAsync(paths.Where(p => string.Equals(System.IO.Path.GetExtension(p), ".pdf", StringComparison.OrdinalIgnoreCase)));
    }

    private async Task AddAsync(IEnumerable<string> paths)
    {
        if (Host is not { } host) return;
        var list = _entries;
        foreach (string path in paths)
        {
            if (await SourceFile.OpenAsync(host, path) is { } document) list.Add(new CombineEntry(System.IO.Path.GetFileName(path), document.Pages.Count, document));
        }
    }
}
