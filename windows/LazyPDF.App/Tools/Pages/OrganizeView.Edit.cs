// What the bar and the keys do: each handler changes the open document and commits it as one step.

using System.Globalization;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Pages;

public sealed partial class OrganizeView
{
    private void TurnLeft_Click(object sender, RoutedEventArgs e) => Turn(Selected(), -90);

    private void TurnRight_Click(object sender, RoutedEventArgs e) => Turn(Selected(), 90);

    // The bar over a page turns that page alone.
    private void Thumbs_Click(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource is FrameworkElement { DataContext: PageCell cell, Tag: string degrees })
            Turn([cell.Index], int.Parse(degrees, CultureInfo.InvariantCulture));
    }

    private void Turn(List<int> pages, int degrees)
    {
        if (Tab is not { } tab || Host is not { } host || pages.Count == 0) return;
        if (PageJobs.Apply(tab, host, Loc.T("Rotate pages"), d => PageOperations.Rotate(d, pages, degrees),
                           Loc.Plural(pages.Count, "{0} page rotated", "{0} pages rotated", pages.Count))) Reselect(tab, pages);
    }

    private void Remove_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        if (Tab is not { } tab || Host is not { } host || pages.Count == 0) return;
        if (NoneLeft(pages, host)) return;
        PageJobs.Apply(tab, host, Loc.T("Delete pages"), d => PageOperations.Delete(d, pages), Loc.Plural(pages.Count, "{0} page deleted", "{0} pages deleted", pages.Count));
    }

    private bool NoneLeft(List<int> pages, IToolHost host)
    {
        if (pages.Count < Cells.Count) return false;
        host.ShowProblem(new Problem(Loc.T("Cannot delete every page"), Loc.T("A file needs at least one page. Leave one page out of the selection.")));
        return true;
    }

    private async void Duplicate_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        if (Tab is not { } tab || Host is not { } host || pages.Count == 0) return;
        if (await PageJobs.ApplyAsync(tab, host, Loc.T("Copying pages"), Loc.T("Duplicate pages"), d => PageOperations.Duplicate(d, pages),
                                      Loc.Plural(pages.Count, "{0} page duplicated", "{0} pages duplicated", pages.Count))) Reselect(tab, PageEdits.Duplicated(pages));
    }

    private bool MoveTo(IReadOnlyCollection<int> pages, int before)
    {
        if (Tab is not { } tab || Host is not { } host) return false;
        if (!PageJobs.Apply(tab, host, Loc.T("Move pages"), d => PageOperations.Move(d, pages, before),
                            Loc.Plural(pages.Count, "{0} page moved", "{0} pages moved", pages.Count))) return false;
        Reselect(tab, PageEdits.MovedTo(pages, before));
        return true;
    }

    private async void Extract_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        if (Tab is not { } tab || Host is not { } host || pages.Count == 0) return;
        var failed = new Problem(Loc.T("Pages not extracted"), Loc.T("The pages could not be copied into a new file. Try fewer pages."));
        if (await PageJobs.CopyOutAsync(tab, host, pages, Loc.T("Extracting pages"), failed) is not { } bytes) return;
        if (!await host.OpenNewAsync(bytes, Loc.T("{0} extract.pdf", System.IO.Path.GetFileNameWithoutExtension(tab.Title)))) return;
        host.SetStatus(Loc.Plural(pages.Count, "{0} page extracted", "{0} pages extracted", pages.Count));
        CopyRules.NoteUnprotected(tab.Document, host);
    }

    private async void Copy_Click(object sender, RoutedEventArgs e) => await CopyAsync(Selected());

    private async void Cut_Click(object sender, RoutedEventArgs e)
    {
        var pages = Selected();
        if (Tab is not { } tab || Host is not { } host || pages.Count == 0 || NoneLeft(pages, host)) return;
        if (!await CopyAsync(pages)) return;
        PageJobs.Apply(tab, host, Loc.T("Cut pages"), d => PageOperations.Delete(d, pages), Loc.Plural(pages.Count, "{0} page cut", "{0} pages cut", pages.Count));
    }

    // True when the pages are on the clipboard.
    private async Task<bool> CopyAsync(List<int> pages)
    {
        if (Tab is not { } tab || Host is not { } host || pages.Count == 0) return false;
        var failed = new Problem(Loc.T("Pages not copied"), Loc.T("The pages could not be copied. Try fewer pages."));
        if (await PageJobs.CopyOutAsync(tab, host, pages, Loc.T("Copying pages"), failed) is not { } bytes) return false;
        PageClipboard.Set(bytes, pages.Count);
        Refresh();
        host.SetStatus(Loc.Plural(pages.Count, "{0} page copied", "{0} pages copied", pages.Count));
        CopyRules.NoteUnprotected(tab.Document, host);
        return true;
    }

    private async void Paste_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host || PageClipboard.Pdf is not { Length: > 0 } pdf) return;
        int at = InsertIndex();
        int count = PageClipboard.Count;
        if (await PageJobs.ApplyAsync(tab, host, Loc.T("Adding pages"), Loc.T("Paste pages"), d => ImportAll(d, PdfDocument.Open(pdf), at),
                                      Loc.Plural(count, "{0} page pasted", "{0} pages pasted", count))) Reselect(tab, Enumerable.Range(at, count));
    }

    private int InsertIndex() => PageEdits.InsertAt((InsertPlace)Place.SelectedIndex, Selected(), Cells.Count);

    private static void ImportAll(PdfDocument target, PdfDocument source, int at) =>
        PageOperations.ImportPages(target, source, [.. Enumerable.Range(0, source.Pages.Count)], at);

    private void Blank_Click(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Host is not { } host) return;
        int at = InsertIndex();
        if (PageJobs.Apply(tab, host, Loc.T("Insert blank page"), d =>
        {
            var (width, height) = PageEdits.NeighbourSize(d, at);
            PageOperations.InsertBlank(d, at, width, height);
        }, Loc.T("Blank page added."))) Reselect(tab, [at]);
    }

    private async void FromFile_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = Loc.T("PDF files") + "|*.pdf", CheckFileExists = true, Multiselect = true };
        if (dialog.ShowDialog() != true) return;
        await InsertFilesAsync(dialog.FileNames, InsertIndex());
    }

    // The files are opened one by one, then all their pages go in at <paramref name="at"/> as one step.
    internal async Task InsertFilesAsync(IEnumerable<string> paths, int at)
    {
        if (Tab is not { } tab || Host is not { } host) return;
        var files = paths.Where(p => System.IO.Path.GetExtension(p).Equals(".pdf", StringComparison.OrdinalIgnoreCase)).ToList();
        if (files.Count == 0)
        {
            host.ShowProblem(new Problem(Loc.T("Not a PDF"), Loc.T("Only PDF files can be added between pages.")));
            return;
        }
        var sources = new List<PdfDocument>();
        foreach (string path in files)
        {
            if (await SourceFile.OpenAsync(host, path) is { } source) sources.Add(source);
        }
        int added = sources.Sum(s => s.Pages.Count);
        if (added == 0) return;
        if (await PageJobs.ApplyAsync(tab, host, Loc.T("Adding pages"), Loc.T("Insert pages"), d =>
        {
            int place = at;
            foreach (var source in sources)
            {
                ImportAll(d, source, place);
                place += source.Pages.Count;
            }
        }, Loc.Plural(added, "{0} page added", "{0} pages added", added))) Reselect(tab, Enumerable.Range(at, added));
    }
}
