using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.App.Tools.Standards;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

/// <summary>
/// The accessibility tool: the check with its fixes, the tag tree, the figures' descriptions and the reading order
/// read aloud. This file has the check and the way the four views take turns; the others have a file each.
/// </summary>
public partial class AccessibilityPanel : ToolPanel
{
    private readonly ToolAction _check;
    private readonly ToolAction _tag;
    private CancellationTokenSource? _quiet;
    private int _checkTicket;
    private bool _untagged;
    private AccessibilityReport? _report;

    // Each view is built when it is shown, and again when the file changed since.
    private bool _checkStale = true;
    private bool _treeStale = true;
    private bool _readStale = true;

    public AccessibilityPanel()
    {
        InitializeComponent();
        _check = new ToolAction(Loc.T("Check"), "", () => Tab is not null, RunCheckAsync);
        _tag = new ToolAction(Loc.T("Add tags"), "", () => Tab is not null, AddTagsAsync);
    }

    // Adding tags runs as the pinned action so the window holds still while the document is being edited.
    public override ToolAction? Action => ShowTags.IsChecked == true && _untagged ? _tag : _check;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        _rewrites = Tab.Rewrites;
        _checkStale = _treeStale = _readStale = true;
        ShowCheck.IsChecked = true;
        Refresh();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        _quiet?.Cancel();
        _checkTicket++;
        _pictureTicket++;
        _treeTicket++;
        _readTicket++;
        StopReading();
        _report = null;
        DropTree();
        _checked = [];
        _drafts.Clear();
        _figureNumber = 0;
        CheckList.ItemsSource = null;
        TagTree.Items.Clear();
        FigureList.ItemsSource = null;
        OrderList.ItemsSource = null;
        CheckSummary.Text = "";
    }

    private void Tab_Changed(object? sender, EventArgs e)
    {
        _checkStale = _treeStale = _readStale = true;
        StopReading();
        Refresh();
    }

    private void View_Checked(object sender, RoutedEventArgs e)
    {
        if (Tab is null) return;
        CheckView.Visibility = Show(ShowCheck);
        TagsView.Visibility = Show(ShowTags);
        FiguresView.Visibility = Show(ShowFigures);
        ReadView.Visibility = Show(ShowRead);
        if (ShowRead.IsChecked != true) StopReading();
        Refresh();
    }

    private static Visibility Show(RadioButton button) => button.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

    // Brings the view in sight up to date.
    private void Refresh()
    {
        var document = Tab!.Document;
        _untagged = AccessibilityEdits.CanAddTags(document);
        SignedRow.Visibility = document.IsSigned ? Visibility.Visible : Visibility.Collapsed;
        if (ShowCheck.IsChecked == true && _checkStale) _ = CheckQuietlyAsync();
        else if ((ShowTags.IsChecked == true || ShowFigures.IsChecked == true) && _treeStale) _ = LoadTreeAsync();
        else if (ShowRead.IsChecked == true && _readStale) _ = BuildReadAsync();
        RaiseActionChanged();
    }

    private async Task RunCheckAsync()
    {
        if (Tab is null || Host is not { } host) return;
        ShowCheck.IsChecked = true;
        _quiet?.Cancel();
        bool finished = false;
        await host.RunBusyAsync(Loc.T("Checking the file"), async token => finished = await CheckAsync(token));
        if (finished) host.SetStatus(CheckStatus());
    }

    private async Task CheckQuietlyAsync()
    {
        _quiet?.Cancel();
        var source = _quiet = new CancellationTokenSource();
        try
        {
            await CheckAsync(source.Token);
        }
        catch (OperationCanceledException)
        {
        }
    }

    // False when the check did not produce a report.
    private async Task<bool> CheckAsync(CancellationToken token)
    {
        var tab = Tab!;
        int ticket = ++_checkTicket;
        _checkStale = false;
        CheckSummary.Text = Loc.T("Checking the file");
        var open = OpenCopy.Of(tab);
        string name = tab.Title;
        try
        {
            var (report, title, language, canTag) = await Task.Run(() =>
            {
                using var copy = open();
                return (AccessibilityChecker.Check(copy, token), AccessibilityEdits.TitleOf(copy, name), AccessibilityEdits.LanguageOf(copy), AccessibilityEdits.CanAddTags(copy));
            }, token).WaitAsync(token);
            if (ticket != _checkTicket || !ReferenceEquals(tab, Tab)) return false;
            ShowRows(report, title, language, canTag);
            return true;
        }
        catch (OperationCanceledException)
        {
            if (ticket == _checkTicket)
            {
                _report = null;
                CheckList.ItemsSource = null;
                CheckSummary.Text = Loc.T("Check stopped. Press Check to run it again.");
            }
            throw;
        }
        catch (Exception error) when (error is PdfReadException or InvalidOperationException)
        {
            if (ticket != _checkTicket) return false;
            _report = null;
            CheckList.ItemsSource = null;
            CheckSummary.Text = Loc.T("The file could not be checked.");
            return false;
        }
    }

    private void ShowRows(AccessibilityReport report, string title, string language, bool canTag)
    {
        var typed = (CheckList.ItemsSource as IEnumerable<CheckRow>)?.Where(r => r.Edited).ToDictionary(r => r.Editor, r => r.Value) ?? [];
        var rows = report.Items.Select(i => new CheckRow(i, i.Rule == AccessibilityRule.Title ? title : i.Rule == AccessibilityRule.Language ? language : "", canTag)).ToList();
        foreach (var row in rows)
        {
            if (typed.TryGetValue(row.Editor, out string? value)) row.Value = value;
        }
        var focus = FocusedPart();
        CheckList.ItemsSource = rows;
        if (focus is { } kept) Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => Refocus(kept.Row, kept.Name));
        _report = report;
        CheckSummary.Text = Loc.T("{0} passed, {1} failed, {2} need a person.", report.Passed, report.Failed, report.NeedsPerson);
    }

    // The row and control the keyboard is on, so a rebuilt list can give it back.
    private (int Row, string Name)? FocusedPart()
    {
        if (Keyboard.FocusedElement is not FrameworkElement { DataContext: CheckRow row } element || !CheckList.IsAncestorOf(element)) return null;
        int index = ((IList<CheckRow>)CheckList.ItemsSource).IndexOf(row);
        return index < 0 ? null : (index, AutomationProperties.GetName(element));
    }

    private void Refocus(int row, string name)
    {
        if (CheckList.ItemContainerGenerator.ContainerFromIndex(row) is { } container && Named(container, name) is { } control) control.Focus();
    }

    private static FrameworkElement? Named(DependencyObject parent, string name)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is FrameworkElement { Focusable: true, IsVisible: true } element && AutomationProperties.GetName(element) == name) return element;
            if (Named(child, name) is { } deeper) return deeper;
        }
        return null;
    }

    private string CheckStatus() => Loc.T("{0} failed, {1} passed", _report?.Failed ?? 0, _report?.Passed ?? 0);

    private async void RowSave_Click(object sender, RoutedEventArgs e)
    {
        if (Row(sender) is not { } row || Tab is not { } tab) return;
        if (row.Editor == RowEditor.Title && row.Value.Trim().Length == 0)
        {
            Host!.ShowProblem(new Problem(Loc.T("Title is empty"), Loc.T("Type a title for the file, then save it.")));
            return;
        }
        await Apply(tab, row, row.EditorName);
    }

    private async void RowAction_Click(object sender, RoutedEventArgs e)
    {
        if (Row(sender) is not { } row || Tab is not { } tab) return;
        switch (row.Action)
        {
            case RowAction.AddTags:
                ShowTags.IsChecked = true;
                break;
            case RowAction.DescribeFigures:
                ShowFigures.IsChecked = true;
                break;
            default:
                await Apply(tab, row, row.ActionText);
                break;
        }
    }

    private void RowPlace_Click(object sender, RoutedEventArgs e)
    {
        if (Row(sender) is not { } row) return;
        Viewer?.GoToPage(row.NextPage());
        var button = (Button)sender;
        button.Content = row.PlaceText;
        AutomationProperties.SetName(button, row.PlaceText);
    }

    private static CheckRow? Row(object sender) => (sender as FrameworkElement)?.DataContext as CheckRow;

    private Task Apply(DocumentTab tab, CheckRow row, string label) => ChangeGate.RunAsync(tab, Host!, label, () =>
    {
        if (!ReferenceEquals(tab, Tab)) return Task.CompletedTask;
        try
        {
            if (AccessibilityEdits.Apply(tab.Document, row) && tab.Commit(label)) Host!.SetStatus(Loc.T("Saved."));
            else Host!.SetStatus(Loc.T("Nothing to change."));
        }
        catch (ArgumentException)
        {
            Host!.ShowProblem(new Problem(Loc.T("Language is not valid"), Loc.T("Write the language as a tag such as en-US or tr-TR.")));
        }
        catch (PdfReadException)
        {
            tab.Session.Discard();
            Host!.ShowProblem(new Problem(Loc.T("Not saved"), Loc.T("The change could not be written. Save a copy of the file and try again.")));
        }
        return Task.CompletedTask;
    });
}
