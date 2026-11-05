using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Ocr;

/// <summary>What the panel does to the document, apart from the controls.</summary>
public static class OcrWork
{
    public const double Dpi = 300;

    /// <summary>
    /// Reads a copy of the file off the UI thread, so the document can be used meanwhile, and writes the layers into the
    /// document if it is still the one that was read. Null when cancelled, when the language is missing or when the document changed.
    /// </summary>
    public static async Task<OcrResult?> MakeSearchableAsync(DocumentTab tab, IToolHost host, ITextRecognizer recognizer, OcrOptions options)
    {
        var bytes = tab.Session.Current.ToArray();
        int revision = tab.Revision;
        bool dropsLayers = options.Existing == OcrExisting.Replace && HasLayer(tab.Document, options.Pages);
        OcrRead? read = null;
        try
        {
            await host.RunBusyAsync(Loc.T("Reading pages"), async cancel =>
            {
                var progress = new Progress<OcrProgress>(p => host.SetBusyText(OcrStatusText.Status(p.Done, p.Total)));
                read = await Task.Run(() => PdfSearchable.ReadAsync(OcrPages.Open(bytes, tab.Password, tab.Certificate), recognizer, tab.Renderer, options, progress, cancel), cancel);
            });
        }
        catch (InvalidOperationException error)
        {
            host.ShowProblem(new Problem(Loc.T("Language not available"), error.Message));
            return null;
        }
        if (read is null) return null;
        if (tab.Revision != revision)
        {
            host.ShowNotice(Loc.T("The document changed"), Loc.T("Nothing was added. Run it again."));
            return null;
        }

        var result = read.Result;
        if (read.Pages.Count > 0)
        {
            int words = PdfOcrLayer.Add(tab.Document, read.Pages, options.Language);
            result = result with { Words = words, Committed = tab.Commit(OcrStatusText.Label) };
        }
        if (result.Committed) host.SetStatus(Loc.Plural(result.Added, "Made {0} page searchable", "Made {0} pages searchable"));
        else if (result.NoWords == 0 && result.NotRendered == 0) host.SetStatus(OcrStatusText.Nothing);
        if (Left(result, dropsLayers) is { } text) host.ShowNotice(Loc.T("Not every page was read"), text);
        return result;
    }

    /// <summary>Why the file may not be changed; null when it may.</summary>
    public static Problem? Refusal(PdfDocument document) =>
        document.Security is { OpenedAsOwner: false } security && !security.Permissions.HasFlag(PdfPermissions.Modify)
            ? new Problem(Loc.T("This file cannot be changed"), Loc.T("Its permissions do not allow it. Open it with the owner password."))
            : null;

    // False when the change has to wait: the file forbids it, or the info bar asks first and calls go on a yes.
    public static bool Cleared(DocumentTab tab, IToolHost host, Action go, string? caution = null)
    {
        if (OcrWork.Refusal(tab.Document) is { } problem)
        {
            host.ShowProblem(problem);
            return false;
        }
        var cautions = new List<string>();
        if (tab.Document.IsSigned) cautions.Add(Loc.T("This file is signed, so changing it breaks the signatures."));
        if (caution is not null) cautions.Add(caution);
        if (cautions.Count == 0) return true;
        host.ShowNotice(Loc.T("Check before going on"), string.Join(" ", cautions), new NoticeAction(Loc.T("Go on anyway"), go));
        return false;
    }

    /// <summary>Takes our text layer off the pages. Returns how many had one.</summary>
    public static int Remove(DocumentTab tab, IReadOnlyList<int> pages)
    {
        var document = tab.Document;
        int removed = pages.Where(p => p < document.Pages.Count).Count(p => PdfOcrLayer.Remove(document, document.Pages[p]));
        if (removed > 0) tab.Commit(Loc.T("Remove text layer"));
        return removed;
    }

    /// <summary>Changes one word of a page's layer; empty text removes it. False when the word already reads so.</summary>
    public static bool Correct(DocumentTab tab, int page, int index, string text)
    {
        var document = tab.Document;
        var current = PdfOcrLayer.Words(document, document.Pages[page]).FirstOrDefault(w => w.Index == index);
        if (current is null || current.Text == text) return false;
        PdfOcrLayer.Correct(document, document.Pages[page], index, text);
        tab.Commit(Loc.T("Correct word"));
        return true;
    }

    private static bool HasLayer(PdfDocument document, IReadOnlyList<int>? pages) =>
        (pages ?? [.. Enumerable.Range(0, document.Pages.Count)]).Any(p => p < document.Pages.Count && PdfOcrLayer.Has(document, document.Pages[p]));

    private static string? Left(OcrResult result, bool dropsLayers)
    {
        var parts = new List<string>();
        if (result.NotRendered > 0) parts.Add(Loc.Plural(result.NotRendered, "{0} page could not be drawn.", "{0} pages could not be drawn."));
        if (result.NoWords > 0) parts.Add(Loc.Plural(result.NoWords, "No text found on {0} page. Check the language.", "No text found on {0} pages. Check the language."));
        if (result.NoWords > 0 && dropsLayers) parts.Add(Loc.T("Text read earlier on those pages was removed. Undo brings it back."));
        return parts.Count == 0 ? null : string.Join(" ", parts);
    }
}
