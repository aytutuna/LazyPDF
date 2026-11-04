// The stamps already in the file: listing them, loading one into the form to update it, and taking them off.

using System.Windows;
using System.Windows.Controls;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Stamps;

/// <summary>One stamp run of the file, in the list.</summary>
public sealed class RunRow(StampInfo info, int pageCount)
{
    public StampInfo Info { get; } = info;

    public int Id => Info.Id;

    public string Title => Info switch
    {
        { Kind: StampKind.Watermark, Label: "image" } => Loc.T("Picture watermark"),
        { Kind: StampKind.Watermark, Label: { Length: > 0 } label } => label,
        { Kind: StampKind.Watermark } => Loc.T("Watermark"),
        { Kind: StampKind.Background } => Loc.T("Background"),
        { Kind: StampKind.Bates } => Loc.T("Bates numbers"),
        _ => Loc.T("Header and footer"),
    };

    public string Details
    {
        get
        {
            string kind = Info.Kind switch
            {
                StampKind.Watermark => Loc.T("Watermark"),
                StampKind.Background => Loc.T("Background"),
                StampKind.Bates => Loc.T("Bates numbers"),
                _ => Loc.T("Header and footer"),
            };
            string pages = Info.Pages.Count == pageCount ? Loc.T("All pages") : Loc.Plural(Info.Pages.Count, "{0} page", "{0} pages");
            string what = Info.Kind == StampKind.HeaderFooter && Info.Label is { Length: > 0 } text ? text : kind;
            return what + " · " + pages;
        }
    }

    public string Summary => Title + ", " + Details;
}

public sealed partial class StampsPanel
{
    private RunRow? _selected;
    private bool _loading;

    private void BuildRuns()
    {
        var tab = Tab!;
        int? keep = _selected?.Id;
        var rows = new PdfStamper(tab.Document).List().Select(i => new RunRow(i, tab.PageCount)).ToList();
        foreach (var gone in _written.Keys.Where(k => k.Tab == tab.Id && rows.All(r => r.Id != k.Run)).ToList()) _written.Remove(gone);
        _loading = true;
        RunList.ItemsSource = rows;
        RunList.SelectedItem = rows.FirstOrDefault(r => r.Id == keep);
        _loading = false;
        Select(RunList.SelectedItem as RunRow);
        RunsBox.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Select(RunRow? row)
    {
        _selected = row;
        RemoveButton.IsEnabled = row is not null;
        UpdateNote.Visibility = NewButton.Visibility = row is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RunList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading) return;
        Select(RunList.SelectedItem as RunRow);
        if (_selected is { } row) Load(row.Info);
        // A loaded run is already on the pages; its preview waits for the first edit.
        _touched = false;
        _previewOn = _selected is null;
        Refresh();
    }

    private void New_Click(object sender, RoutedEventArgs e) => RunList.SelectedItem = null;

    private async void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (_selected is not { } row) return;
        await TakeOffAsync(Loc.T("Removing the stamp"), document => new PdfStamper(document).Remove(row.Id), Loc.T("Remove stamp"), Loc.T("Stamp removed."));
    }

    private async void RemoveAll_Click(object sender, RoutedEventArgs e) =>
        await TakeOffAsync(Loc.T("Removing the stamps"), document => new PdfStamper(document).RemoveAll(), Loc.T("Remove all stamps"), Loc.T("Stamps removed."));

    private Task TakeOffAsync(string busy, Action<PdfDocument> remove, string label, string status)
    {
        var tab = Tab!;
        var host = Host!;
        return ChangeGate.RunAsync(tab, host, label, () => Working(async () =>
        {
            if (!await EditAsync(tab, host, busy, remove)) return;
            _previewOn = false;
            ClearPreviews();
            if (tab.Commit(label)) host.SetStatus(status);
        }));
    }
}
