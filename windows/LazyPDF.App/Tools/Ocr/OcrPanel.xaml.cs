using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Ocr;

/// <summary>Make searchable: which pages and in what language, then the text layer, and its correction and removal.</summary>
public sealed partial class OcrPanel : ToolPanel
{
    private readonly ITextRecognizer _recognizer;
    private readonly Func<OcrLanguageState> _languages;
    private readonly ToolAction _action;
    private int _generation;
    private bool _filling;
    private bool _loading;
    private bool _running;
    private bool _failed;
    private bool _replaceShown;

    public OcrPanel() : this(new WindowsOcr(), OcrLanguageState.Read)
    {
    }

    internal OcrPanel(ITextRecognizer recognizer, Func<OcrLanguageState> languages)
    {
        _recognizer = recognizer;
        _languages = languages;
        _action = new ToolAction(Loc.T("Make searchable"), "", CanRun, Run);
        InitializeComponent();
    }

    public override ToolAction? Action => _action;

    private bool Replacing => ReplaceLayers.IsChecked == true;

    private bool CanRun() => Tab is not null && !_running && !_loading && LanguageBox.SelectedItem is not null && PageList.SelectedItems.Count > 0;

    protected override void OnAttach()
    {
        var tab = Tab!;
        tab.Changed += Tab_Changed;
        FillLanguages();
        _filling = true;
        PageList.ItemsSource = null;
        _filling = false;
        PagesSummary.Text = "";
        _ = LoadPagesAsync(tab);
        AttachWords();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        _generation++;
        DetachWords();
    }

    private void FillLanguages()
    {
        var state = _languages();
        _filling = true;
        LanguageBox.ItemsSource = state.Installed;
        LanguageBox.SelectedItem = state.Preferred();
        _filling = false;
        FillMoreLanguages();
        MoreLanguagesSection.Visibility = state.Installed.Count >= 2 ? Visibility.Visible : Visibility.Collapsed;
        LanguageNote.Text = state.Advice;
        LanguageGlyph.Text = state.Installed.Count == 0 ? "" : "";
        RaiseActionChanged();
    }

    private void FillMoreLanguages()
    {
        MoreLanguages.ItemsSource = LanguageBox.Items.Cast<OcrLanguage>().Where(l => !ReferenceEquals(l, LanguageBox.SelectedItem)).ToList();
    }

    private async Task LoadPagesAsync(DocumentTab tab)
    {
        int generation = ++_generation;
        var bytes = tab.Session.Current.ToArray();
        _loading = true;
        PagesChanged();
        IReadOnlyList<OcrPageKind>? kinds;
        try
        {
            kinds = await Task.Run(() => OcrPages.Classify(bytes, tab.Password, tab.Certificate));
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            System.Diagnostics.Trace.TraceError(error.ToString());
            kinds = null;
        }
        if (generation != _generation) return;

        _failed = kinds is null;
        _loading = false;
        IReadOnlyList<PageRow> rows = kinds is null ? [] : OcrPages.Rows(kinds);
        _filling = true;
        PageList.ItemsSource = rows;
        _filling = false;
        SelectWanted();
    }

    private void SelectWanted()
    {
        _replaceShown = Replacing;
        _filling = true;
        PageList.SelectedItems.Clear();
        foreach (PageRow row in PageList.Items)
        {
            if (OcrPages.Wanted(row, Replacing)) PageList.SelectedItems.Add(row);
        }
        _filling = false;
        PagesChanged();
    }

    private IReadOnlyList<int> SelectedPages() => [.. PageList.SelectedItems.Cast<PageRow>().Select(r => r.Page).Order()];

    private void PagesChanged()
    {
        bool layers = PageList.Items.Cast<PageRow>().Any(r => r.Kind == OcrPageKind.OwnLayer);
        bool chosen = PageList.SelectedItems.Cast<PageRow>().Any(r => r.Kind == OcrPageKind.OwnLayer);
        RemoveButton.IsEnabled = !_loading && chosen;
        RemoveNote.Text = _loading || chosen ? "" : layers ? Loc.T("Choose pages marked Searchable above.") : Loc.T("No page has a text layer from here.");
        RemoveNote.Visibility = RemoveNote.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (!_loading) ShowSummary();
        RaiseActionChanged();
    }

    private void ShowSummary()
    {
        int needed = PageList.Items.Cast<PageRow>().Count(r => OcrPages.Wanted(r, Replacing));
        PagesSummary.Text = _failed
            ? Loc.T("The pages could not be checked.")
            : needed == 0 ? OcrStatusText.Nothing : Loc.T("{0} of {1} pages need it.", needed, PageList.Items.Count);
    }

    private async Task Run()
    {
        if (Tab is not { } tab || Host is not { } host || LanguageBox.SelectedItem is not OcrLanguage language) return;
        var options = new OcrOptions(language.Tag, OcrWork.Dpi, Replacing ? OcrExisting.Replace : OcrExisting.Skip, SelectedPages(), Force: true);
        IReadOnlyList<string> languages = [language.Tag, .. MoreLanguages.SelectedItems.Cast<OcrLanguage>().Select(l => l.Tag)];
        int texted = PageList.SelectedItems.Cast<PageRow>().Count(r => r.Kind is OcrPageKind.ForeignLayer or OcrPageKind.Text);
        string? doubled = texted == 0 ? null : Loc.Plural(texted,
            "{0} chosen page already has text. Reading it adds a second layer, so search finds words twice.",
            "{0} chosen pages already have text. Reading them adds a second layer, so search finds words twice.");
        if (OcrWork.Cleared(tab, host, () => ReadAnyway(tab, host, options, languages), doubled)) await Read(tab, host, options, languages);
    }

    // The panel is off while the pages are read: a change to the document then would waste the run.
    private async Task Read(DocumentTab tab, IToolHost host, OcrOptions options, IReadOnlyList<string> languages)
    {
        bool done = false;
        _running = true;
        IsEnabled = false;
        RaiseActionChanged();
        try
        {
            var result = await OcrWork.MakeSearchableAsync(tab, host, _recognizer, options, languages);
            done = result is { Committed: true };
        }
        finally
        {
            _running = false;
            IsEnabled = true;
            RaiseActionChanged();
        }
        if (done && ReferenceEquals(Tab, tab) && host.TakeReturnTool() is { } back) host.OpenTool(back);
    }

    // Runs from the info bar, which the shell's handling of a failed action does not reach.
    private async void ReadAnyway(DocumentTab tab, IToolHost host, OcrOptions options, IReadOnlyList<string> languages)
    {
        if (!ReferenceEquals(Tab, tab)) return;
        try
        {
            await Read(tab, host, options, languages);
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            host.ShowProblem(new Problem(Loc.T("Something went wrong"), Loc.T("{0} could not be finished. If part of it was done, Undo takes it back.", _action.Text)));
            System.Diagnostics.Trace.TraceError(error.ToString());
        }
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        if (!_correcting) _ = LoadPagesAsync(Tab!);
        RefreshWords();
    }

    private void LanguageBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_filling) return;
        FillMoreLanguages();
        RaiseActionChanged();
    }

    private void PageList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_filling) PagesChanged();
    }

    private void Existing_Click(object sender, RoutedEventArgs e)
    {
        if (Replacing == _replaceShown) return;
        // Only the pages the mode decides about move, so a choice made by hand stays.
        _filling = true;
        foreach (PageRow row in PageList.Items)
        {
            if (OcrPages.Wanted(row, _replaceShown) == OcrPages.Wanted(row, Replacing)) continue;
            if (Replacing) PageList.SelectedItems.Add(row);
            else PageList.SelectedItems.Remove(row);
        }
        _filling = false;
        _replaceShown = Replacing;
        PagesChanged();
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var pages = SelectedPages();
        if (OcrWork.Cleared(tab, host, () => RemoveAnyway(tab, host, pages))) Remove(tab, host, pages);
    }

    private void RemoveAnyway(DocumentTab tab, IToolHost host, IReadOnlyList<int> pages)
    {
        if (ReferenceEquals(Tab, tab)) Remove(tab, host, pages);
    }

    private static void Remove(DocumentTab tab, IToolHost host, IReadOnlyList<int> pages)
    {
        int removed = OcrWork.Remove(tab, pages);
        if (removed > 0) host.SetStatus(Loc.Plural(removed, "Removed from {0} page", "Removed from {0} pages"));
    }
}
