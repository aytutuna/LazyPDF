using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

/// <summary>
/// Marks what is to go by drawing, by selecting, by searching and by shape, lets the marks be looked over, and
/// writes the redacted copy as a new file. The marks live in the panel, per document, until the copy is made.
/// </summary>
public partial class RedactPanel : ToolPanel
{
    // What the panel remembers of a document while another tool or tab is in front.
    private sealed class RedactState
    {
        public MarkList Marks { get; } = new();

        public RedactSummary? Result { get; set; }

        // The page objects in order, to know when marks, which are kept by page number, no longer fit the pages.
        public int[]? Pages { get; set; }
    }

    private static readonly ConditionalWeakTable<DocumentTab, RedactState> States = [];

    private readonly IFontSource _fonts = new SystemFontSource();
    private readonly IImageCodec _images = new WicImageCodec();
    private readonly ToolAction _action;
    private RedactState? _state;
    private bool _restricted;
    private bool _working;
    private bool _editing;
    private RedactBoxEditor? _editor;

    // The copy opens as a tab of its own; the panel finds that tab by its title when it is attached there.
    private RedactSummary? _incoming;
    private string _incomingTitle = "";

    public RedactPanel()
    {
        InitializeComponent();
        KindBox.ItemsSource = DataKind.All;
        KindBox.SelectedIndex = 0;
        CoverBox.ItemsSource = Cover.All;
        CoverBox.SelectedIndex = 0;
        _action = new ToolAction(Loc.T("Redact to a new file"), "", () => !_restricted && _state?.Marks.Items.Count > 0, RunAsync);
    }

    public override ToolAction? Action => _action;

    protected override void OnAttach()
    {
        var tab = Tab!;
        _state = States.GetOrCreateValue(tab);
        if (_incoming is not null && tab.Path is null && tab.Title == _incomingTitle)
        {
            _state.Result = _incoming;
            _incoming = null;
        }
        _restricted = RedactJob.Refuses(tab.Document);
        Body.IsEnabled = !_restricted;
        RestrictedNote.Visibility = _restricted ? Visibility.Visible : Visibility.Collapsed;
        DropMarksOfOtherPages();
        tab.PendingMarks = _state.Marks.Items.Count;
        _state.Marks.Changed += Marks_Changed;
        tab.Changed += Tab_Changed;
        Viewer!.SelectionChanged += Viewer_SelectionChanged;
        Viewer.ModeChanged += Viewer_ModeChanged;
        _editor = new RedactBoxEditor(Viewer, BoxEdited, text => Host?.SetStatus(text), FocusSelectedRow);
        ShowMarks();
        ShowResult();
        ShowSelectionNote();
        RaiseActionChanged();
    }

    protected override void OnDetach()
    {
        DrawToggle.IsChecked = false;
        _editor!.Detach();
        _editor = null;
        ClearOverlays();
        _state!.Marks.Changed -= Marks_Changed;
        Tab!.Changed -= Tab_Changed;
        Viewer!.SelectionChanged -= Viewer_SelectionChanged;
        Viewer.ModeChanged -= Viewer_ModeChanged;
        MarkedList.ItemsSource = null;
        _state = null;
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        DropMarksOfOtherPages();
        _editor!.Clear();
        DrawOverlays(redrawAll: true);
    }

    private void DropMarksOfOtherPages()
    {
        var state = _state!;
        int[] pages = [.. Tab!.Document.Pages.Select(p => p.Reference.Number)];
        bool moved = state.Pages is { } before && !before.SequenceEqual(pages);
        state.Pages = pages;
        if (!moved) return;
        bool any = state.Marks.Items.Count > 0;
        state.Marks.Clear();
        state.Marks.Forget();
        if (!any) return;
        Host!.ShowNotice(Loc.T("Marks removed"), Loc.T("The pages changed, so the marks no longer fit. Mark them again."));
    }

    private void Marks_Changed(object? sender, EventArgs e)
    {
        Tab!.PendingMarks = _state!.Marks.Items.Count;
        ShowMarks();
        RaiseActionChanged();
    }
}
