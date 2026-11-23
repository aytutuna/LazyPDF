using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Pages;

/// <summary>Pages going from one tab to another, or out into a tab of their own. The caller gates a paste into the tab it works on; a copy into another tab gates itself.</summary>
internal static class PageTransfer
{
    /// <summary>Puts the pages of <paramref name="pdf"/> into <paramref name="target"/> at <paramref name="at"/>, or at its end when null. The end is read from the document being changed, so it cannot be stale.</summary>
    public static Task<bool> PasteAsync(DocumentTab target, IToolHost host, byte[] pdf, int count, int? at) =>
        PageJobs.ApplyAsync(target, host, Loc.T("Adding pages"), Loc.T("Paste pages"), d =>
        {
            var source = PdfDocument.Open(pdf);
            PageOperations.ImportPages(d, source, [.. Enumerable.Range(0, source.Pages.Count)], Math.Min(at ?? d.Pages.Count, d.Pages.Count));
        }, Loc.Plural(count, "{0} page pasted", "{0} pages pasted", count));

    /// <summary>Copies the dragged or chosen pages to the end of <paramref name="to"/>, which is not the tab they are in.</summary>
    public static Task CopyAsync(PagePayload from, DocumentTab to, IToolHost host) =>
        ChangeGate.RunAsync(to, host, Loc.T("Copy pages"), () => Transfer(from, to, host), to.Title);

    private static async Task Transfer(PagePayload from, DocumentTab to, IToolHost host)
    {
        if (ReferenceEquals(from.Tab, to)) return;
        if (!host.OpenDocuments.Contains(from.Tab) || !host.OpenDocuments.Contains(to))
        {
            Refuse(host, Loc.T("One of the two files is not open any more."));
            return;
        }
        if (Changed(from))
        {
            Refuse(host, Loc.T("The pages changed since they were picked. Pick them again."));
            return;
        }
        if (MarkWork.Running)
        {
            Refuse(host, Loc.T("Wait for the running job to finish, then try again."));
            return;
        }
        if (!to.Drawing.IsCompleted)
        {
            Refuse(host, Loc.T("{0} is still loading. Try again in a moment.", to.Title));
            return;
        }
        var failed = new Problem(Loc.T("Pages not copied"), Loc.T("The pages could not be copied. Try fewer pages."));
        if (await PageJobs.CopyOutAsync(from.Tab, host, from.Pages, Loc.T("Copying pages"), failed, files: false) is not var (bytes, _, _)) return;
        if (!await PasteAsync(to, host, bytes, from.Pages.Length, null)) return;
        host.SetStatus(Loc.Plural(from.Pages.Length, "Copied {0} page to {1}. Undo it in {1}.", "Copied {0} pages to {1}. Undo it in {1}.", to.Title));
        CopyRules.NoteUnprotected(from.Tab.Document, host);
    }

    /// <summary>Makes a new tab of the pages. The Extract buttons pass <paramref name="files"/> to take the attachments along, a drag or a menu does not.</summary>
    public static async Task ToNewTabAsync(PagePayload from, IToolHost host, bool files)
    {
        if (Changed(from))
        {
            Refuse(host, Loc.T("The pages changed since they were picked. Pick them again."));
            return;
        }
        var failed = new Problem(Loc.T("Pages not extracted"), Loc.T("The pages could not be copied into a new file. Try fewer pages."));
        if (await PageJobs.CopyOutAsync(from.Tab, host, from.Pages, Loc.T("Extracting pages"), failed, files) is not var (bytes, skipped, dropped)) return;
        if (!await host.OpenNewAsync(bytes, Loc.T("{0} extract.pdf", System.IO.Path.GetFileNameWithoutExtension(from.Tab.Title)))) return;
        PageJobs.NoteSkippedAttachments(host, skipped, dropped);
        host.SetStatus(Loc.Plural(from.Pages.Length, "{0} page extracted", "{0} pages extracted", from.Pages.Length));
        CopyRules.NoteUnprotected(from.Tab.Document, host);
    }

    private static bool Changed(PagePayload from) =>
        from.Tab.Revision != from.Revision || from.Pages.Any(p => p < 0 || p >= from.Tab.PageCount);

    private static void Refuse(IToolHost host, string text) => host.ShowProblem(new Problem(Loc.T("Pages not copied"), text));
}
