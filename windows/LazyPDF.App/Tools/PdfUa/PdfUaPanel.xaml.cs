using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.App.Tools.Standards;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.PdfUa;

/// <summary>
/// Checks the file against PDF/UA-1 and, when the check finds nothing but what marking writes itself, marks it. The words
/// say that the file passes Lazy PDF's checks and never that it conforms.
/// </summary>
public partial class PdfUaPanel : ToolPanel
{
    // The most rows listed; the rest are counted.
    private const int RowsShown = 100;

    private readonly ToolAction _check;
    private int _ticket;
    private bool _working;

    public PdfUaPanel()
    {
        InitializeComponent();
        PersonNote.Text = Loc.T("Reading order, what alt text says and contrast need a person. The Accessibility tool lists them.");
        Caveat.Text = Loc.T("These are Lazy PDF's own checks. No outside validator has confirmed them.");
        _check = new ToolAction(Loc.T("Check"), "", () => Tab is not null && !_working, CheckAsync);
    }

    public override ToolAction? Action => _check;

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Clear();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        _ticket++;
        Result.Visibility = Visibility.Collapsed;
        IssueList.ItemsSource = null;
    }

    // What a verdict says is about the bytes it was made from.
    private void Tab_Changed(object? sender, EventArgs e) => Clear();

    private void Clear()
    {
        _ticket++;
        Result.Visibility = Visibility.Collapsed;
        MarkRow.Visibility = Visibility.Collapsed;
        IssueList.ItemsSource = null;
        RaiseActionChanged();
    }

    private async Task CheckAsync()
    {
        if (Tab is not { } tab || Host is not { } host) return;
        int ticket = ++_ticket;
        var open = OpenCopy.Of(tab);
        Task<UaOutcome>? run = null;
        _working = true;
        try
        {
            UaOutcome? outcome = null;
            await host.RunBusyAsync(Loc.T("Checking PDF/UA-1"), async token =>
            {
                run = Task.Run(() =>
                {
                    using var copy = open();
                    return UaOutcome.Of(copy, token);
                }, token);
                outcome = await run.WaitAsync(token);
            });
            if (outcome is null || ticket != _ticket || !ReferenceEquals(tab, Tab)) return;
            Show(outcome);
            host.SetStatus(outcome.Status);
        }
        catch (Exception error) when (error is PdfReadException or InvalidOperationException)
        {
            host.ShowProblem(new Problem(Loc.T("Not checked"), Loc.T("The file could not be checked.")));
        }
        finally
        {
            Release(run);
        }
    }

    private void Show(UaOutcome outcome)
    {
        var rows = IssueRow.Group(outcome.Report.Issues);
        Verdict.Text = outcome.Verdict(rows.Count);
        MarkNote.Text = Loc.T("Nothing else is wrong. Marking writes the PDF/UA-1 identifier into the file.");
        MarkRow.Visibility = outcome.CanMark ? Visibility.Visible : Visibility.Collapsed;
        IssueList.ItemsSource = rows.Take(RowsShown).ToList();
        Rest.Text = rows.Count > RowsShown ? Loc.T("{0} more conditions are not listed.", rows.Count - RowsShown)
            : outcome.Report.Truncated ? Loc.T("The list stops at 1000 findings.")
            : "";
        Rest.Visibility = Rest.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        Result.Visibility = Visibility.Visible;
    }

    private async void Mark_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host || _working) return;
        string name = Loc.T("Mark as PDF/UA");
        await ChangeGate.RunAsync(tab, host, name, async () =>
        {
            if (!ReferenceEquals(tab, Tab)) return;
            var document = tab.Document;
            PdfUaMarkResult? result = null;
            _working = true;
            RaiseActionChanged();
            try
            {
                await host.RunBusyAsync(name, async token =>
                {
                    try
                    {
                        result = await Task.Run(() => PdfUaValidator.Mark(document, DateTimeOffset.Now, token));
                    }
                    catch (OperationCanceledException)
                    {
                        // The job edits the open document, so Cancel waits for it to stop and takes back what it wrote.
                        tab.Session.Discard();
                        throw;
                    }
                });
            }
            finally
            {
                Idle();
            }
            if (result is null) return;
            if (!result.Marked)
            {
                host.ShowProblem(new Problem(Loc.T("Not marked"), Loc.T("The file does not pass the checks, or its metadata cannot be changed. Check it again.")));
                return;
            }
            if (!tab.Commit(name)) return;
            host.ShowNotice(Loc.T("Marked as PDF/UA-1"), Loc.T("The file now names PDF/UA-1. It passes Lazy PDF's checks; a person still has to judge the reading order and the alt text."));
            await CheckAsync();
        });
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
