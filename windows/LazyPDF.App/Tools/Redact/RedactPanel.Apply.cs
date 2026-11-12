// Making the redacted copy and saying what came of it.
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Redact;

public partial class RedactPanel
{
    private async Task RunAsync()
    {
        if (_working) return;
        var tab = Tab!;
        var host = Host!;
        var state = _state!;
        var applied = state.Marks.Items.ToList();
        var marks = applied.Where(m => m.Value is null).Select(m => m.Mark).ToList();
        var values = applied.Where(m => m.Value is not null).Select(m => m.Value!).ToList();
        var settings = new RedactSettings((Cover)CoverBox.SelectedItem, OverlayBox.Text, FlattenBox.IsChecked == true);
        byte[] bytes = [];
        int revision = tab.Revision;
        bool encrypted = tab.Document.IsEncrypted;
        var stale = new Problem(Loc.T("Not redacted"), Loc.T("The file changed meanwhile. Try again."));
        RedactionResult? result = null;
        _working = true;
        try
        {
            await host.RunBusyAsync(Loc.T("Redacting"), async token =>
            {
                // The renderer must draw the bytes that are redacted, so a load still running is waited for.
                await tab.Drawing.WaitAsync(token);
                bytes = tab.Session.Current.ToArray();
                revision = tab.Revision;
                result = await Task.Run(() => RedactJob.Apply(bytes, tab.Password, tab.Certificate, marks, settings, tab.Renderer, _fonts, _images, values)).WaitAsync(token);
            });
        }
        catch (Exception error) when (error is InvalidOperationException or UnauthorizedAccessException or PdfReadException)
        {
            host.ShowProblem(tab.Revision != revision ? stale : RedactJob.Failed(error));
            return;
        }
        finally
        {
            _working = false;
        }
        if (result is null) return;
        if (tab.Revision != revision)
        {
            host.ShowProblem(stale);
            return;
        }

        var summary = RedactSummary.Of(result, settings.FlattenAll);
        var (oldIncoming, oldTitle) = (_incoming, _incomingTitle);
        // Set before the open: the new tab picks the summary up while it attaches.
        _incoming = summary;
        _incomingTitle = Loc.T("{0} (redacted).pdf", System.IO.Path.GetFileNameWithoutExtension(tab.Title));
        if (!await host.OpenNewAsync(result.Bytes, _incomingTitle))
        {
            (_incoming, _incomingTitle) = (oldIncoming, oldTitle);
            return;
        }

        // The marks are done with once the copy is open; the panel may be detached by now, so the count is set here too.
        // One drawn while the copy was opening is not in it and stays.
        if (state.Marks.Items.SequenceEqual(applied)) state.Marks.Clear();
        else foreach (var item in applied) state.Marks.Remove(item);
        state.Marks.Forget();
        tab.PendingMarks = state.Marks.Items.Count;
        host.SetStatus(summary.Clean ? Loc.T("Redacted copy opened.") : Loc.T("Redacted copy has problems."));
        if (encrypted) host.ShowNotice(Loc.T("The copy has no password"), Loc.T("Protect it before you share it."));
    }

    private void ShowResult()
    {
        var result = _state!.Result;
        ResultCard.Visibility = result is null ? Visibility.Collapsed : Visibility.Visible;
        if (result is null) return;
        ResultGlyph.Text = result.Clean ? "" : "";
        ResultGlyph.SetResourceReference(System.Windows.Controls.TextBlock.ForegroundProperty, result.Clean ? "SystemFillColorSuccessBrush" : "SystemFillColorCautionBrush");
        ResultTitle.Text = result.Title;
        ResultAdvice.Text = result.Advice;
        ResultReport.Text = result.Report;
        ResultProblems.Text = result.Problems;
        ResultProblems.Visibility = result.Problems.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        ResultNotChecked.Text = result.NotChecked;
    }
}
