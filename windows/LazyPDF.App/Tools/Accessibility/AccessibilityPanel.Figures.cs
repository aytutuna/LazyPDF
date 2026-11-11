using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

// The figures of the file, each with its picture beside the box for its description.
public partial class AccessibilityPanel
{
    private int _pictureTicket;

    // What a tab keeps while another tab or tool is shown: the text typed for its figures and not saved yet, by the
    // figure's key, the figures it was checked against, and the rewrite count the keys belong to.
    private sealed class FigureState
    {
        public Dictionary<int, string> Drafts { get; } = [];
        public IReadOnlyList<FigureRow> Checked { get; set; } = [];
        public Dictionary<int, string> Written { get; } = [];
        public int Rewrites { get; set; }
    }

    private static readonly ConditionalWeakTable<DocumentTab, FigureState> States = [];

    private FigureState _state = new();

    // The figure to show when the list is built: the one that was shown, or the next one after a save.
    private int _figureNumber;

    private FigureRow? Selected => FigureList.SelectedItem as FigureRow;

    private void RenderFigures()
    {
        var rows = _figures;
        FigureList.ItemsSource = rows;
        FigureList.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        int bare = rows.Count(r => !r.HasDescription);
        FiguresNote.Text = _treeFailed ? Loc.T("The tags could not be read.")
            : _tree is null ? Loc.T("The file has no tags, so no figures are known. Add tags first.")
            : _tree.IsTruncated ? Loc.T("The tags are too large to list every figure.")
            : rows.Count == 0 ? Loc.T("The file has no figures.")
            : bare == 0 ? Loc.T("Every figure has a description.")
            : Loc.T("{0} of {1} figures have no description.", bare, rows.Count);
        if (rows.Count == 0) return;
        int keep = _figureNumber - 1;
        FigureList.SelectedIndex = keep >= 0 && keep < rows.Count ? keep : Math.Max(rows.ToList().FindIndex(r => !r.HasDescription), 0);
    }

    private void FigureList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var row = Selected;
        var shown = row is null ? Visibility.Collapsed : Visibility.Visible;
        FigureEditor.Visibility = shown;
        FigureButtons.Visibility = shown;
        if (row is null) return;
        _figureNumber = row.Number;
        AltBox.Text = _state.Drafts.TryGetValue(row.Key, out string? draft) ? draft : row.Alt;
        RememberDraft();
        NextBare.IsEnabled = _figures.Any(r => !r.HasDescription);
        if (row.Page >= 0) Viewer?.GoToPage(row.Page);
        _ = ShowPictureAsync(row);
    }

    private async Task ShowPictureAsync(FigureRow row)
    {
        var tab = Tab!;
        var copy = _treeCopy;
        int ticket = ++_pictureTicket;
        FigurePicture.Source = null;
        FigureNoPicture.Visibility = Visibility.Collapsed;
        BitmapSource? picture = null;
        if (copy is not null && tab.Renderer is WindowsPageRenderer renderer)
        {
            // The copy is read by one picture at a time, and a picture nobody waits for any more is not looked for.
            var box = await Task.Run(() =>
            {
                lock (copy) return ticket == _pictureTicket ? FigureFinder.Box(copy, row.Element, row.Page) : null;
            });
            if (box is { } found && ticket == _pictureTicket)
            {
                var region = new DisplayRect(found.X - 4, found.Y - 4, found.Width + 8, found.Height + 8);
                double dpi = Math.Clamp(200 * 72 / region.Width, 36, 288);
                if (await renderer.RenderRegionAsync(row.Page, region, dpi) is { } image) picture = Pixels.ToBitmap(image);
            }
        }
        if (ticket != _pictureTicket) return;
        FigurePicture.Source = picture;
        FigureNoPicture.Visibility = picture is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AltBox_TextChanged(object sender, TextChangedEventArgs e) => RememberDraft();

    private void RememberDraft()
    {
        if (Selected is not { } row)
        {
            SaveAlt.IsEnabled = false;
            return;
        }
        bool changed = AltBox.Text.Trim() != row.Alt;
        if (changed) _state.Drafts[row.Key] = AltBox.Text;
        else _state.Drafts.Remove(row.Key);
        SaveAlt.IsEnabled = changed;
    }

    private async void SaveAlt_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } row || Tab is not { } tab) return;
        string text = AltBox.Text;
        bool shown = false;
        await ChangeGate.RunAsync(tab, Host!, Loc.T("Figure description"), () =>
        {
            shown = Selected?.Key == row.Key;
            if (!ReferenceEquals(tab, Tab) || !WriteAlts(tab, [(row, text)])) return Task.CompletedTask;
            if (_state.Drafts.TryGetValue(row.Key, out var draft) && draft.Trim() == text.Trim()) _state.Drafts.Remove(row.Key);
            if (shown) _figureNumber = text.Trim().Length > 0 ? NextBareAfter(row.Number, row.Number) : row.Number;
            return Task.CompletedTask;
        });
    }

    public override bool KeepsDrafts => true;

    // Typed descriptions go into the file with Save's rules, as one undo step; a signed file asks first, so the caller is told to wait.
    public override bool HandIn()
    {
        if (Tab is not { } tab || _state.Drafts.Count == 0) return true;
        var edits = _state.Checked.Where(r => _state.Drafts.ContainsKey(r.Key)).Select(r => (r, _state.Drafts[r.Key])).ToList();
        if (edits.Count == 0) return true;
        bool asks = tab.Document.IsSigned && ChangeGate.Refusal(tab.Document) is null;
        _ = ChangeGate.RunAsync(tab, Host!, Loc.T("Figure description"), () =>
        {
            if (ReferenceEquals(tab, Tab) && WriteAlts(tab, edits)) foreach (var (row, _) in edits) _state.Drafts.Remove(row.Key);
            return Task.CompletedTask;
        });
        return !asks;
    }

    private bool WriteAlts(DocumentTab tab, IReadOnlyList<(FigureRow Row, string Text)> edits)
    {
        try
        {
            // The tree on the screen was read from a copy; the edit goes to the open document's own.
            var tree = StructureTree.Read(tab.Document);
            var figures = tree is null ? [] : FigureFinder.List(tree);
            var found = edits.Select(e => figures.FirstOrDefault(f => f.Key == e.Row.Key)).ToList();
            if (tree is null || edits.Where((e, i) => AccessibilityEdits.FigureChanged(found[i]?.Element, e.Row.Alt)).Any())
            {
                Host!.ShowProblem(new Problem(Loc.T("Description not saved"), Loc.T("The figure is no longer in the file.")));
                return false;
            }
            for (int i = 0; i < edits.Count; i++)
            {
                AccessibilityEdits.SetAlt(tab.Document, tree, found[i]!.Element, edits[i].Text);
                _state.Written[edits[i].Row.Key] = edits[i].Text.Trim();
            }
            if (tab.Commit(Loc.T("Figure description"))) Host!.SetStatus(Loc.T("Description saved."));
            return true;
        }
        catch (Exception error) when (error is InvalidOperationException or PdfReadException)
        {
            tab.Session.Discard();
            Host!.ShowProblem(new Problem(Loc.T("Description not saved"), Loc.T("The tags of this file are too large to change here.")));
            return false;
        }
    }

    private void NextBare_Click(object sender, RoutedEventArgs e)
    {
        if (Selected is not { } row) return;
        int number = NextBareAfter(row.Number, 0);
        FigureList.SelectedIndex = number - 1;
        FigureList.ScrollIntoView(_figures[number - 1]);
    }

    // The number of the next figure with no description, wrapping round, and counting the one just saved as described.
    private int NextBareAfter(int number, int saved)
    {
        for (int step = 1; step <= _figures.Count; step++)
        {
            int index = (number - 1 + step) % _figures.Count;
            if (index + 1 != saved && !_figures[index].HasDescription) return index + 1;
        }
        return number;
    }
}
