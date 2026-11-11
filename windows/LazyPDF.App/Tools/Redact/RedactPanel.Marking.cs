// Putting marks on: the drawing tool, the selection and the two kinds of search.
using System.Windows;
using System.Windows.Input;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

public partial class RedactPanel
{
    private RedactDrawTool? _tool;

    private void DrawToggle_Changed(object sender, RoutedEventArgs e)
    {
        if (Viewer is not { } viewer) return;
        if (DrawToggle.IsChecked == true)
        {
            _tool = new RedactDrawTool(viewer, BoxDrawn);
            viewer.PointerTool = _tool;
        }
        else if (ReferenceEquals(viewer.PointerTool, _tool))
        {
            viewer.PointerTool = null;
        }
    }

    private void Viewer_ModeChanged(object? sender, EventArgs e) => DrawToggle.IsChecked = false;

    private void BoxDrawn(int page, Point from, Point to)
    {
        var mark = MarkShapes.Box(page, Viewer!.Geometry(page), from, to);
        _state!.Marks.Add([new MarkItem(mark, Loc.T("Box"))]);
    }

    private void Viewer_SelectionChanged(object? sender, EventArgs e) => ShowSelectionNote();

    private void ShowSelectionNote()
    {
        bool any = Viewer!.HasSelection;
        MarkSelectionButton.IsEnabled = any;
        SelectionNote.Visibility = any ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void MarkSelection_Click(object sender, RoutedEventArgs e)
    {
        var viewer = Viewer!;
        var host = Host!;
        var state = _state!;
        var runs = await viewer.GetSelectionAsync();
        int added = state.Marks.Add(runs.Where(r => r.Quads.Count > 0).Select(r => new MarkItem(new RedactionMark(r.Page, r.Quads), RedactJob.Clip(r.Text))));
        if (added > 0) viewer.ClearSelection();
        host.SetStatus(Added(added));
    }

    private void QueryBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        FindWordsButton.IsEnabled = !string.IsNullOrWhiteSpace(QueryBox.Text);
        ShowQueryNote(null);
    }

    private void RegexBox_Changed(object sender, RoutedEventArgs e)
    {
        bool regex = RegexBox.IsChecked == true;
        WholeWordBox.IsEnabled = !regex;
        QueryLabel.Text = regex ? Loc.T("Patterns, one per line") : Loc.T("Words or phrases, one per line");
        RegexNote.Visibility = regex ? Visibility.Visible : Visibility.Collapsed;
        ShowQueryNote(null);
    }

    private void ShowQueryNote(string? text)
    {
        QueryNote.Text = text;
        QueryNote.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void QueryBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Keyboard.Modifiers != ModifierKeys.Control || !FindWordsButton.IsEnabled) return;
        e.Handled = true;
        FindWords_Click(sender, e);
    }

    private async void FindWords_Click(object sender, RoutedEventArgs e)
    {
        bool regex = RegexBox.IsChecked == true;
        var terms = QueryBox.Text.Split(['\r', '\n'], regex ? StringSplitOptions.RemoveEmptyEntries : StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.Ordinal).ToList();
        if (terms.Count > 200)
        {
            Host!.ShowProblem(new(Loc.T("Too many lines"), Loc.T("Use 200 or fewer words or phrases.")));
            return;
        }
        bool matchCase = MatchCaseBox.IsChecked == true, whole = WholeWordBox.IsChecked == true;
        if (regex)
        {
            if (RedactJob.CheckPatterns(QueryBox.Text.ReplaceLineEndings("\n").Split('\n')) is { } problem)
            {
                ShowQueryNote(problem);
                QueryBox.Focus();
                return;
            }
            await FindAsync((document, token) => RedactJob.FindPatterns(document, terms, matchCase, token));
            return;
        }
        await FindAsync((document, token) => RedactJob.Find(document, terms, matchCase, whole, token));
    }

    private async void FindKind_Click(object sender, RoutedEventArgs e)
    {
        var kind = (DataKind)KindBox.SelectedItem;
        await FindAsync((document, token) => RedactJob.Find(document, kind, token));
    }

    private async Task FindAsync(Func<PdfDocument, CancellationToken, Found> find)
    {
        if (_working) return;
        var tab = Tab!;
        var host = Host!;
        var state = _state!;
        byte[] bytes = tab.Session.Current.ToArray();
        string? password = tab.Password;
        var certificate = tab.Certificate;
        Found? found = null;
        _working = true;
        try
        {
            await host.RunBusyAsync(Loc.T("Searching"), async token =>
            {
                found = await Task.Run(() =>
                {
                    using var document = RedactJob.Open(bytes, password, certificate);
                    return find(document, token);
                }, token);
                token.ThrowIfCancellationRequested();
            });
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            host.ShowProblem(new(Loc.T("Search failed"), Loc.T("The file could not be searched. Close it and open it again.")));
            return;
        }
        finally
        {
            _working = false;
        }
        if (found is null) return;
        host.SetStatus(found.Items.Count == 0 ? Loc.T("Nothing found.") : Added(state.Marks.Add(found.Items)));
        if (found.Pictures > 0)
        {
            host.ShowNotice(Loc.Plural(found.Pictures, "{0} page has no text", "{0} pages have no text"),
                            Loc.T("Words and numbers on those pages were not searched. Draw boxes over them instead."));
        }
    }

    private static string Added(int count) =>
        count == 0 ? Loc.T("Nothing new to mark.") : Loc.Plural(count, "{0} mark added.", "{0} marks added.");
}
