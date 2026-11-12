using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>What the Pages inspector and the organize view both do with a tab: one change to the document as one undo step, and pages copied out.</summary>
internal static class PageJobs
{
    public static bool Apply(DocumentTab tab, IToolHost host, string label, Action<PdfDocument> change, string status)
    {
        try
        {
            change(tab.Document);
        }
        catch (Exception error) when (error is ArgumentException or PdfReadException)
        {
            Refuse(host, tab);
            return false;
        }
        return Commit(tab, host, label, status);
    }

    public static void Delete(DocumentTab tab, IToolHost host, string label, IReadOnlyCollection<int> pages, string status)
    {
        bool tagged = IsTagged(tab);
        if (Apply(tab, host, label, d => PageOperations.Delete(d, pages), status)) NoticeIfUntagged(tab, host, tagged);
    }

    public static bool IsTagged(DocumentTab tab) => tab.Document.Dict(tab.Document.Catalog, "StructTreeRoot") is not null;

    public static void NoticeIfUntagged(DocumentTab tab, IToolHost host, bool wasTagged)
    {
        if (wasTagged && !IsTagged(tab))
            host.ShowNotice(Loc.T("Tags removed"), Loc.T("This file was tagged for screen readers. A deleted page was tagged, so the tags are gone. Undo brings them back."));
    }

    // For the edits that copy pages in from another file: the work runs off the UI thread and the result goes to the tab it started on,
    // wherever the person has moved to meanwhile.
    public static async Task<bool> ApplyAsync(DocumentTab tab, IToolHost host, string busy, string label, Action<PdfDocument> change, string status)
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
        if (done) return Commit(tab, host, label, status);
        tab.Session.Discard();
        return false;
    }

    private static bool Commit(DocumentTab tab, IToolHost host, string label, string status)
    {
        try
        {
            if (!tab.Commit(label)) return false;
        }
        catch (PdfReadException)
        {
            Refuse(host, tab);
            return false;
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

    // The files are opened one by one, then all their pages go in at <paramref name="at"/> as one step. Returns the pages added.
    public static async Task<int> InsertFilesAsync(DocumentTab tab, IToolHost host, IEnumerable<string> paths, int at)
    {
        var files = paths.Where(p => System.IO.Path.GetExtension(p).Equals(".pdf", StringComparison.OrdinalIgnoreCase)).ToList();
        if (files.Count == 0)
        {
            host.ShowProblem(new Problem(Loc.T("Not a PDF"), Loc.T("Only PDF files can be added between pages.")));
            return 0;
        }
        var sources = new List<PdfDocument>();
        foreach (string path in files)
        {
            if (await SourceFile.OpenAsync(host, path) is { } source) sources.Add(source);
        }
        int added = sources.Sum(s => s.Pages.Count);
        if (added == 0) return 0;
        bool done = await ApplyAsync(tab, host, Loc.T("Adding pages"), Loc.T("Insert pages"), d =>
        {
            int place = at;
            foreach (var source in sources)
            {
                PageOperations.ImportPages(d, source, [.. Enumerable.Range(0, source.Pages.Count)], place);
                place += source.Pages.Count;
            }
        }, Loc.Plural(added, "{0} page added", "{0} pages added", added));
        return done ? added : 0;
    }

    /// <summary>The pages as a PDF of their own, made off the UI thread, with the count of attachments left out. Null when the file does not allow copying, when it was cancelled or when it failed, with <paramref name="failed"/> shown.</summary>
    public static async Task<(byte[] Bytes, int Skipped)?> CopyOutAsync(DocumentTab tab, IToolHost host, IReadOnlyList<int> pages, string busy, Problem failed, bool files = true)
    {
        if (CopyRules.Refused(tab.Document, host)) return null;
        byte[]? bytes = null;
        int skipped = 0;
        try
        {
            await host.RunBusyAsync(busy, token => Task.Run(() =>
            {
                using var copy = PageAssembly.Extract(PageEdits.Reopen(tab), pages, token, files);
                byte[] made = copy.SaveRewrite();
                token.ThrowIfCancellationRequested();
                bytes = made;
                skipped = copy.SkippedAttachments;
            }, token));
        }
        catch (Exception error) when (error is PdfReadException or ArgumentException)
        {
            host.ShowProblem(failed);
            return null;
        }
        return bytes is null ? null : (bytes, skipped);
    }

    // Shown by the caller once the result is open or saved, since opening a tab clears a notice from the tab it came from.
    internal static void NoteSkippedAttachments(IToolHost host, int skipped)
    {
        if (skipped == 0) return;
        host.ShowNotice(Loc.T("Attachments left out"), SkippedText(skipped));
    }

    internal static string SkippedText(int skipped) =>
        skipped == 0 ? "" : Loc.Plural(skipped, "{0} attachment could not be read and was left out.", "{0} attachments could not be read and were left out.");
}
