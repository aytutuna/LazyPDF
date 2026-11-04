using LazyPDF.App.Documents;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.EditContent;

// Replace all: the words of the whole file, on every page at once.
public sealed partial class EditContentPanel
{
    private bool _replacing;

    private void Find_TextChanged(object sender, TextChangedEventArgs e) =>
        ReplaceAllButton.IsEnabled = FindBox.Text.Length > 0;

    private void Find_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || FindBox.Text.Length == 0) return;
        e.Handled = true;
        ReplaceAll_Click(sender, e);
    }

    private async void ReplaceAll_Click(object sender, RoutedEventArgs e)
    {
        if (_edits is null || Host is null || _tab is null || _replacing || FindBox.Text.Length == 0) return;
        FinishPending();
        if (!Allowed(() => ReplaceAll_Click(sender, e))) return;
        var edits = _edits;
        var host = Host;
        var tab = _tab;
        byte[] start = tab.Session.Current.ToArray();
        string find = FindBox.Text, replacement = ReplaceBox.Text;
        var options = new TextSearchOptions(MatchCase: MatchCase.IsChecked == true, WholeWord: WholeWord.IsChecked == true);
        Replacement? made = null;
        _replacing = true;
        IsEnabled = false;
        try
        {
            await host.RunBusyAsync(Loc.T("Replacing text"), token => Task.Run(() => made = edits.ReplaceAll(start, find, replacement, options, token), token));
            if (made is null) return;
            var outcome = edits.Adopt(made);
            if (outcome.Done) host.SetStatus(Loc.T("Text replaced."));
            if (!ReferenceEquals(tab, _tab)) return;
            _surface!.Clear();
            ShowOutcome(outcome);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            System.Diagnostics.Trace.TraceError(error.ToString());
            host.ShowProblem(new Problem(Loc.T("Text not replaced"), Loc.T("The file could not be changed. Try again or open it again.")));
        }
        finally
        {
            _replacing = false;
            IsEnabled = true;
        }
    }
}
