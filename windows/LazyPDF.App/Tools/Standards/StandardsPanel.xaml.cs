using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Standards;

/// <summary>
/// Checks the file against a PDF/A level and converts it to one. The words say that the file passes Lazy PDF's
/// checks and never that it conforms: the validator has not been compared with an outside one.
/// </summary>
public partial class StandardsPanel : ToolPanel
{
    // The most rows listed; the rest are counted.
    private const int RowsShown = 100;

    private static readonly PdfALevel[] Levels = [.. Enum.GetValues<PdfALevel>().OrderBy(l => l.Part()).ThenBy(l => l.Conformance())];

    private PdfALevel _level = PdfALevel.A2b;
    private ToolAction _check = null!;
    private ToolAction _convert = null!;
    private int _ticket;
    private int _probe;
    private bool _working;

    public StandardsPanel()
    {
        InitializeComponent();
        Caveat.Text = Loc.T("These are Lazy PDF's own checks. No outside validator has confirmed them.");
        foreach (var level in Levels) LevelBox.Items.Add(level.Name());
        LevelBox.SelectedIndex = Array.IndexOf(Levels, _level);
        Mode_Checked(this, new RoutedEventArgs());
    }

    public override ToolAction? Action => ModeConvert.IsChecked == true ? _convert : _check;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Clear();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        _ticket++;
        _probe++;
        TagRow.Visibility = Visibility.Collapsed;
        Result.Visibility = Visibility.Collapsed;
        IssueList.ItemsSource = null;
    }

    // What a verdict says is about the bytes it was made from.
    private void Tab_Changed(object? sender, EventArgs e) => Clear();

    private void Clear()
    {
        _ticket++;
        Result.Visibility = Visibility.Collapsed;
        IssueList.ItemsSource = null;
        ShowLosses();
        RaiseActionChanged();
        _ = FindTaggingAsync();
    }

    // Read off the UI thread from a copy; a change, another level or leaving the panel before it ends drops the answer.
    private async Task FindTaggingAsync()
    {
        int probe = ++_probe;
        TagRow.Visibility = Visibility.Collapsed;
        if (Tab is not { } tab || !_level.NeedsTags()) return;
        var level = _level;
        var open = OpenCopy.Of(tab);
        bool needs;
        try
        {
            needs = await Task.Run(() => StandardsText.NeedsTagging(open, level));
        }
        catch (Exception e) when (e is PdfReadException or InvalidOperationException)
        {
            return;
        }
        if (probe != _probe) return;
        TagNote.Text = StandardsText.TagHint(level);
        TagRow.Visibility = needs ? Visibility.Visible : Visibility.Collapsed;
    }

    private void TagFile_Click(object sender, RoutedEventArgs e) => Host?.OpenTool("accessibility");

    private void Mode_Checked(object sender, RoutedEventArgs e)
    {
        if (ModeNote is null) return;
        ModeNote.Text = ModeConvert.IsChecked == true
            ? Loc.T("Makes a new file and tries to meet the level. This file stays as it is.")
            : Loc.T("Lists the rules the file breaks. Nothing is changed.");
        ShowLosses();
        RaiseActionChanged();
    }

    private void ShowLosses()
    {
        string losses = ModeConvert.IsChecked == true && Tab is { } tab ? StandardsText.Losses(tab.Document.IsSigned, tab.Document.IsEncrypted) : "";
        WarnNote.Text = losses;
        WarnRow.Visibility = losses.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void LevelBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LevelBox.SelectedIndex < 0) return;
        _level = Levels[LevelBox.SelectedIndex];
        LevelNote.Text = StandardsText.Describe(_level);
        _check = new ToolAction(Loc.T("Check"), "", () => Tab is not null && !_working, CheckAsync);
        _convert = new ToolAction(Loc.T("Convert to {0}", _level.Name()), "", () => Tab is not null && !_working, ConvertAsync);
        if (Tab is not null) Clear();
        else RaiseActionChanged();
    }

    private async Task CheckAsync()
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var level = _level;
        int ticket = ++_ticket;
        var open = OpenCopy.Of(tab);
        Task<PdfAReport>? run = null;
        _working = true;
        try
        {
            PdfAReport? report = null;
            await host.RunBusyAsync(Loc.T("Checking {0}", level.Name()), async token =>
            {
                run = Task.Run(() =>
                {
                    using var copy = open();
                    return PdfAValidator.Validate(copy, level);
                });
                report = await run.WaitAsync(token);
            });
            if (report is null || ticket != _ticket || !ReferenceEquals(tab, Tab)) return;
            Show(report);
            host.SetStatus(report.IsValid ? Loc.T("Passes Lazy PDF's {0} checks.", level.Name()) : Loc.T("Fails {0} checks.", level.Name()));
        }
        finally
        {
            Release(run);
        }
    }

    private void Show(PdfAReport report)
    {
        var rows = IssueRow.Group(report.Issues);
        string name = report.Level.Name();
        Verdict.Text = report.IsValid
            ? Loc.T("Passes Lazy PDF's checks for {0}.", name)
            : Loc.T("Does not pass the checks for {0}. Rules broken: {1}.", name, rows.Count);
        IssueList.ItemsSource = rows.Take(RowsShown).ToList();
        Rest.Text = rows.Count > RowsShown ? Loc.T("{0} more rules are not listed.", rows.Count - RowsShown)
            : report.Truncated ? Loc.T("The list stops at 1000 findings.")
            : "";
        Rest.Visibility = Rest.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        Result.Visibility = Visibility.Visible;
    }

    private async Task ConvertAsync()
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var level = _level;
        var job = new ConvertJob(tab);
        Task<PdfAConversion>? run = null;
        bool opened = false;
        _working = true;
        try
        {
            PdfAConversion? made = null;
            await host.RunBusyAsync(Loc.T("Converting to {0}", level.Name()), async token =>
            {
                run = Task.Run(() => job.Run(level, new SystemFontSource()));
                made = await run.WaitAsync(token);
            });
            if (made is null) return;
            if (made.Bytes is null)
            {
                host.ShowProblem(new Problem(Loc.T("Not converted"), made.Refusal ?? Loc.T("The file could not be converted.")));
                return;
            }
            if (!await host.OpenNewAsync(made.Bytes, StandardsText.ConvertedName(tab.Title, level, made.IsClean))) return;
            host.ShowNotice(StandardsText.ConvertedTitle(made), StandardsText.ConvertedText(made, level));
            opened = Tab is { } now && !ReferenceEquals(now, tab);
        }
        finally
        {
            Release(run);
        }
        if (opened) await CheckAsync();
    }

    // Core cannot stop a run that has begun. After Cancel the run is let go, but the button waits until it ends so that runs do not pile up.
    private void Release(Task? run)
    {
        if (run is { IsCompleted: false }) _ = WaitOutAsync(run);
        else Idle();
    }

    private async Task WaitOutAsync(Task run)
    {
        try
        {
            await run;
        }
        catch (Exception)
        {
            // Nobody is waiting for its result any more.
        }
        Idle();
    }

    private void Idle()
    {
        _working = false;
        RaiseActionChanged();
    }

    private void Place_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not IssueRow row) return;
        Viewer?.GoToPage(row.NextPage());
        var button = (Button)sender;
        button.Content = row.PlaceText;
        AutomationProperties.SetName(button, row.PlaceText);
    }
}
