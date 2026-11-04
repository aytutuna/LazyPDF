// The bar over the grid, and the insert section: each handler changes the open document and commits it as one step.

using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Pages;

internal sealed record PickedPages(PdfDocument Source, List<int> Pages);

public partial class PagesPanel
{
    private bool Apply(string label, Action<PdfDocument> change, IEnumerable<int>? reselect, string status)
    {
        if (Tab is not { } tab || Host is not { } host) return false;
        try
        {
            change(tab.Document);
        }
        catch (Exception error) when (error is ArgumentException or PdfReadException)
        {
            Refuse(host, tab);
            return false;
        }
        return Commit(host, tab, label, reselect, status);
    }

    // For the edits that copy pages in from another file: the work runs off the UI thread and the result goes to the tab it started on,
    // wherever the person has moved to meanwhile.
    private async Task<bool> ApplyAsync(DocumentTab tab, IToolHost host, string busy, string label, Action<PdfDocument> change, IEnumerable<int>? reselect, string status)
    {
        bool done = false;
        try
        {
            await host.RunBusyAsync(busy, token => Task.Run(() =>
            {
                token.ThrowIfCancellationRequested();
                change(tab.Document);
                done = !token.IsCancellationRequested;
            }, token));
        }
        catch (Exception error) when (error is ArgumentException or PdfReadException)
        {
            Refuse(host, tab);
            return false;
        }
        if (done) return Commit(host, tab, label, reselect, status);
        tab.Session.Discard();
        return false;
    }

    private bool Commit(IToolHost host, DocumentTab tab, string label, IEnumerable<int>? reselect, string status)
    {
        _reselect = ReferenceEquals(Tab, tab) ? reselect : null;
        try
        {
            if (!tab.Commit(label)) return false;
        }
        catch (PdfReadException)
        {
            Refuse(host, tab);
            return false;
        }
        finally
        {
            _reselect = null;
        }
        host.SetStatus(status);
        return true;
    }

    // What was changed in memory is dropped, so a half-done edit cannot be committed later with another one.
    internal static void Refuse(IToolHost host, DocumentTab tab)
    {
        tab.Session.Discard();
        host.ShowProblem(new Problem(Loc.T("Pages not changed"), Loc.T("The file did not take that change. Pick other pages and try again.")));
    }

    private void TurnLeft_Click(object sender, RoutedEventArgs e) => Turn(-90);

    private void TurnRight_Click(object sender, RoutedEventArgs e) => Turn(90);

    private void Turn(int degrees)
    {
        var pages = Selected();
        Apply(Loc.T("Rotate pages"), d => PageOperations.Rotate(d, pages, degrees), pages, Loc.Plural(pages.Count, "{0} page rotated", "{0} pages rotated", pages.Count));
    }

    private async void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var pages = Selected();
        await ApplyAsync(tab, host, Loc.T("Copying pages"), Loc.T("Duplicate pages"), d => PageOperations.Duplicate(d, pages), PageEdits.Duplicated(pages),
                         Loc.Plural(pages.Count, "{0} page duplicated", "{0} pages duplicated", pages.Count));
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        if (pages.Count == Cells.Count)
        {
            Host!.ShowProblem(new Problem(Loc.T("Cannot delete every page"), Loc.T("A file needs at least one page. Leave one page out of the selection.")));
            return;
        }
        Apply(Loc.T("Delete pages"), d => PageOperations.Delete(d, pages), null, Loc.Plural(pages.Count, "{0} page deleted", "{0} pages deleted", pages.Count));
    }

    private void Earlier_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        MoveTo(pages, pages[0] - 1);
    }

    private void Later_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        MoveTo(pages, pages[^1] + 2);
    }

    private bool MoveTo(IReadOnlyCollection<int> pages, int before) =>
        Apply(Loc.T("Move pages"), d => PageOperations.Move(d, pages, before), PageEdits.MovedTo(pages, before), Loc.Plural(pages.Count, "{0} page moved", "{0} pages moved", pages.Count));

    private async void Extract_Click(object sender, RoutedEventArgs e)
    {
        var tab = Tab!;
        var host = Host!;
        var pages = Selected();
        if (CopyRules.Refused(tab.Document, host)) return;
        byte[]? bytes = null;
        try
        {
            await host.RunBusyAsync(Loc.T("Extracting pages"), token => Task.Run(() =>
            {
                byte[] made = PageAssembly.Extract(PageEdits.Reopen(tab), pages).SaveRewrite();
                token.ThrowIfCancellationRequested();
                bytes = made;
            }, token));
        }
        catch (Exception error) when (error is PdfReadException or ArgumentException)
        {
            host.ShowProblem(new Problem(Loc.T("Pages not extracted"), Loc.T("The pages could not be copied into a new file. Try fewer pages.")));
            return;
        }
        if (bytes is null) return;
        await host.OpenNewAsync(bytes, Loc.T("{0} extract.pdf", System.IO.Path.GetFileNameWithoutExtension(tab.Title)));
        host.SetStatus(Loc.Plural(pages.Count, "{0} page extracted", "{0} pages extracted", pages.Count));
        CopyRules.NoteUnprotected(tab.Document, host);
    }

    private void Blank_Click(object sender, RoutedEventArgs e)
    {
        var selection = Selected();
        int at = PageEdits.InsertAt((InsertPlace)Place.SelectedIndex, selection, Cells.Count);
        Apply(Loc.T("Insert blank page"), d =>
        {
            var (width, height) = PageEdits.NeighbourSize(d, at);
            PageOperations.InsertBlank(d, at, width, height);
        }, [at], Loc.T("Blank page added."));
    }

    private async void FromFile_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var selection = Selected();
        int at = PageEdits.InsertAt((InsertPlace)Place.SelectedIndex, selection, Cells.Count);
        if (await PickPagesAsync(host, Taken.Text) is not { } picked) return;
        var (source, taken) = picked;
        await ApplyAsync(tab, host, Loc.T("Adding pages"), Loc.T("Insert pages"), d => PageOperations.ImportPages(d, source, taken, at), Enumerable.Range(at, taken.Count),
                         Loc.Plural(taken.Count, "{0} page added", "{0} pages added", taken.Count));
    }

    private async void Replace_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var selection = Selected();
        if (selection.Count == 0) return;
        if (await PickPagesAsync(host, Taken.Text) is not { } picked) return;
        var (source, taken) = picked;
        await ApplyAsync(tab, host, Loc.T("Replacing pages"), Loc.T("Replace pages"), d => PageEdits.Replace(d, selection, source, taken),
                         Enumerable.Range(selection.Max() + 1 - selection.Count, taken.Count), Loc.T("Pages replaced."));
    }

    // A PDF chosen by the person, opened off the UI thread, with the pages the box asks for. Null when there is none to use.
    private static async Task<PickedPages?> PickPagesAsync(IToolHost host, string text)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("PDF files") + "|*.pdf", CheckFileExists = true };
        if (dialog.ShowDialog() != true) return null;
        if (await SourceFile.OpenAsync(host, dialog.FileName) is not { } source) return null;
        var range = text.Trim().Length == 0 ? null : PageRange.Parse(text, source.Pages.Count);
        if (range?.Error is { } error)
        {
            host.ShowProblem(new Problem(Loc.T("Pages not understood"), error.Message));
            return null;
        }
        return new PickedPages(source, range is null ? [.. Enumerable.Range(0, source.Pages.Count)] : [.. range.Pages]);
    }
}
