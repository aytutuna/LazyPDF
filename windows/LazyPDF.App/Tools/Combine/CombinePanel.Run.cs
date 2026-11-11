// The pinned button: combining the list into one file, or cutting this file into parts, then opening or saving the result.

using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Pages;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Combine;

public partial class CombinePanel
{
    // Parts open as tabs only up to this many; more than that goes to a folder.
    private const int MostTabs = 3;

    private bool ToFolder => Output.SelectedIndex == 1;

    private async Task CombineAsync()
    {
        var tab = Tab!;
        var host = Host!;
        var documents = _entries.Select(entry => entry.Document ?? tab.Document).Distinct().ToList();
        if (documents.Any(document => CopyRules.Refused(document, host))) return;
        var sources = new List<(CombineEntry Entry, List<int>? Pages)>();
        foreach (var entry in _entries)
        {
            var range = entry.Range.Trim().Length == 0 ? null : PageRange.Parse(entry.Range, entry.Pages);
            if (range?.Error is { } error)
            {
                host.ShowProblem(new Problem(Loc.T("Pages not understood"), Loc.T("{0}: {1}", entry.Name, error.Message)));
                return;
            }
            sources.Add((entry, range is null ? null : [.. range.Pages]));
        }
        string? folder = ToFolder ? PickFolder() : null;
        if (ToFolder && folder is null) return;
        bool bookmarks = BookmarkEach.IsChecked == true;

        byte[]? bytes = null;
        int skipped = 0;
        try
        {
            await host.RunBusyAsync(Loc.T("Combining files"), token => Task.Run(() =>
            {
                // The open document is read again here: its pages may be taken twice and the session belongs to the UI thread.
                var again = PageEdits.Reopen(tab);
                using var merged = PageAssembly.Merge([.. sources.Select(s => new MergeSource(s.Entry.Document ?? again, s.Pages))], token);
                if (bookmarks) CombineJob.AddFileBookmarks(merged, [.. sources.Select(s => (s.Entry.Name, s.Pages?.Count ?? (s.Entry.Document ?? again).Pages.Count))]);
                byte[] made = merged.SaveRewrite();
                token.ThrowIfCancellationRequested();
                bytes = made;
                skipped = merged.SkippedAttachments;
            }, token));
        }
        catch (Exception error) when (error is PdfReadException or ArgumentException)
        {
            string? bad = null;
            bool checkedAll = false;
            try
            {
                await host.RunBusyAsync(Loc.T("Checking the files"), token => Task.Run(() =>
                {
                    using var open = PageEdits.Reopen(tab);
                    bad = FirstUnmergeable(open, sources, token);
                    checkedAll = true;
                }, token));
            }
            catch (Exception again) when (again is PdfReadException or ArgumentException)
            {
                // Reopening failed again, so no file can be named.
                host.ShowProblem(new Problem(Loc.T("Files not combined"), Loc.T("The files could not be put into one. Try fewer pages or files.")));
                return;
            }
            if (!checkedAll) return;
            host.ShowProblem(new Problem(Loc.T("Files not combined"), bad is null
                ? Loc.T("The files could not be put into one. Try fewer pages or files.")
                : Loc.T("{0} could not be put into the file. Leave it out, or try fewer of its pages.", bad)));
            return;
        }
        if (bytes is null) return;
        PageJobs.NoteSkippedAttachments(host, skipped);

        string name = Loc.T("Combined.pdf");
        bool protectedSource = documents.Any(document => document.IsEncrypted);
        if (folder is not null)
        {
            Saved(host, folder, [(name, bytes)], protectedSource, "");
            return;
        }
        if (!await host.OpenNewAsync(bytes, name)) return;
        if (protectedSource) host.ShowNotice(Loc.T("Copy is not protected"), CopyRules.Unprotected);
    }

    internal static string? FirstUnmergeable(PdfDocument open, IEnumerable<(CombineEntry Entry, List<int>? Pages)> sources, CancellationToken token = default)
    {
        foreach (var (entry, pages) in sources)
        {
            try
            {
                using var merged = PageAssembly.Merge([new MergeSource(entry.Document ?? open, pages)], token);
                merged.SaveRewrite();
            }
            catch (Exception error) when (error is PdfReadException or ArgumentException)
            {
                return entry.Name;
            }
        }
        return null;
    }

    private async Task SplitAsync()
    {
        var tab = Tab!;
        var host = Host!;
        if (!CombineJob.TryAmount(Kind, Amount.Text, out double amount, tab.PageCount)) return;
        var kind = Kind;
        var ranges = CombineJob.ParseRanges(kind == SplitBy.Ranges ? Amount.Text : "", tab.PageCount).Ranges;
        if (CopyRules.Refused(tab.Document, host)) return;
        if (kind == SplitBy.Bookmarks && CombineJob.BookmarkParts(tab.Document) < 2)
        {
            host.ShowProblem(new Problem(Loc.T("Nothing to cut at"), Loc.T("No bookmark starts after the first page. Split by pages or size instead.")));
            return;
        }
        var titles = kind == SplitBy.Bookmarks ? CombineJob.BookmarkTitles(tab.Document) : [];
        string? folder = ToFolder ? PickFolder() : null;
        if (ToFolder && folder is null) return;
        List<byte[]>? parts = null;
        int skipped = 0;
        try
        {
            await host.RunBusyAsync(Loc.T("Splitting file"), token => Task.Run(() =>
            {
                var saved = new List<byte[]>();
                foreach (var part in CombineJob.Split(PageEdits.Reopen(tab), kind, amount, token, ranges))
                {
                    token.ThrowIfCancellationRequested();
                    saved.Add(part.SaveRewrite());
                    skipped += part.SkippedAttachments;
                }
                parts = saved;
            }, token));
        }
        catch (Exception error) when (error is PdfReadException or ArgumentException)
        {
            host.ShowProblem(new Problem(Loc.T("File not split"), Loc.T("The parts could not be made. Try a different amount.")));
            return;
        }
        if (parts is null) return;
        PageJobs.NoteSkippedAttachments(host, skipped);
        if (parts.Count < 2 && kind != SplitBy.Ranges)
        {
            host.ShowNotice(Loc.T("Nothing to split"), Loc.T("The whole file fits in one part. Use a smaller amount."));
            return;
        }

        string big = kind == SplitBy.Size ? CombineJob.Oversize(parts, amount) : "";

        string stem = System.IO.Path.GetFileNameWithoutExtension(tab.Title);
        var named = parts.Select((bytes, i) => (CombineJob.PartName(stem, i, parts.Count, i < titles.Count ? titles[i] : null), bytes)).ToList();
        if (folder is null && parts.Count > MostTabs)
        {
            host.ShowNotice(Loc.T("Too many parts for tabs"), Loc.T("These make {0} files. Pick a folder for them.", parts.Count));
            folder = PickFolder();
            if (folder is null) return;
        }
        if (folder is not null)
        {
            Saved(host, folder, named, tab.Document.IsEncrypted, big);
            return;
        }
        int opened = 0;
        foreach (var (name, bytes) in named)
        {
            if (await host.OpenNewAsync(bytes, name)) opened++;
        }
        if (opened == 0) return;
        if (opened < parts.Count)
        {
            // The info bar still says which part failed, so the word on protection goes in the status.
            string some = Loc.T("{0} of {1} parts opened.", opened, parts.Count);
            if (big.Length > 0) some += " " + big;
            host.SetStatus(tab.Document.IsEncrypted ? some + " " + CopyRules.Unprotected : some);
            return;
        }
        string all = Loc.T("{0} parts opened.", opened);
        host.SetStatus(big.Length > 0 ? all + " " + big : all);
        CopyRules.NoteUnprotected(tab.Document, host);
    }

    private string? PickFolder()
    {
        var dialog = new OpenFolderDialog { Title = Loc.T("Save to a folder"), InitialDirectory = _folder ?? System.IO.Path.GetDirectoryName(Tab?.Path) ?? "" };
        if (dialog.ShowDialog() != true) return null;
        _folder = dialog.FolderName;
        return _folder;
    }

    internal static void Saved(IToolHost host, string folder, IReadOnlyList<(string Name, byte[] Bytes)> files, bool protectedSource, string extra)
    {
        string first = "";
        try
        {
            foreach (var (name, bytes) in files)
            {
                string path = CombineJob.UniquePath(folder, name);
                File.WriteAllBytes(path, bytes);
                if (first.Length == 0) first = path;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(Problems.Save(error, System.IO.Path.GetFileName(folder)));
            return;
        }
        host.ShowNotice(Loc.Plural(files.Count, "{0} file saved", "{0} files saved", files.Count), CombineJob.FolderNote(folder, protectedSource, extra), new NoticeAction(Loc.T("Open the first"), () => _ = host.OpenAsync(first)));
    }
}
