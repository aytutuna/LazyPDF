using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools.Pages;
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
    public static async Task<OcrResult?> MakeSearchableAsync(DocumentTab tab, IToolHost host, ITextRecognizer recognizer, OcrOptions options,
                                                                 IReadOnlyList<string>? languages = null)
    {
        byte[] bytes = [];
        int revision = tab.Revision;
        bool dropsLayers = options.Existing == OcrExisting.Replace && HasLayer(tab.Document, options.Pages);
        OcrRead? read = null;
        var reading = new Reading(tab.Renderer, recognizer, languages ?? [options.Language]);
        try
        {
            await host.RunBusyAsync(Loc.T("Reading pages"), async cancel =>
            {
                var progress = new Progress<OcrProgress>(p => host.SetBusyText(OcrStatusText.Status(p.Done, p.Total)));
                await tab.Drawing.WaitAsync(cancel);
                bytes = tab.Session.Current.ToArray();
                revision = tab.Revision;
                read = await Task.Run(() => PdfSearchable.ReadAsync(OcrPages.Open(bytes, tab.Password, tab.Certificate), reading, reading, options, progress, cancel), cancel);
            });
        }
        catch (InvalidOperationException error)
        {
            host.ShowProblem(new Problem(Loc.T("Language not available"), error.Message));
            return null;
        }
        if (read is null)
        {
            // A cancel is swallowed by the host, so the pages read so far are all that is left of the run.
            if (reading.Pages.Count == 0 || tab.Revision != revision) return null;
            var document = tab.Document;
            var had = reading.Pages.Where(p => PdfOcrLayer.Has(document, document.Pages[p.PageIndex])).ToList();
            Write(document, reading.Pages, reading.Turns, options.Language);
            if (!tab.Commit(OcrStatusText.Label)) return null;
            int stopped = reading.Pages.Count(p => PdfOcrLayer.Has(document, document.Pages[p.PageIndex]));
            var parts = new List<string>();
            if (stopped > 0)
            {
                host.SetStatus(Loc.Plural(stopped, "Made {0} page searchable", "Made {0} pages searchable"));
                parts.Add(Loc.Plural(stopped, "Stopped after {0} page. The page was kept. Undo takes it back.", "Stopped after {0} pages. The pages were kept. Undo takes them back."));
            }
            if (had.Any(p => !PdfOcrLayer.Has(document, document.Pages[p.PageIndex]))) parts.Add(Loc.T("Text read earlier on those pages was removed. Undo brings it back."));
            if (reading.Turns.Count > 0) parts.Add(Turned(reading.Turns.Count));
            host.ShowNotice(Loc.T("Reading stopped"), string.Join(" ", parts));
            return null;
        }
        if (tab.Revision != revision)
        {
            host.ShowNotice(Loc.T("The file changed"), Loc.T("Nothing was added. Run it again."));
            return null;
        }

        var result = read.Result;
        if (read.Pages.Count > 0)
        {
            int words = Write(tab.Document, reading.Pages, reading.Turns, options.Language);
            result = result with { Words = words, Committed = tab.Commit(OcrStatusText.Label) };
        }
        if (result.Committed) host.SetStatus(Loc.Plural(result.Added, "Made {0} page searchable", "Made {0} pages searchable"));
        else if (result.NoWords == 0 && result.NotRendered == 0) host.SetStatus(OcrStatusText.Nothing);
        if (Left(result, dropsLayers) is { } text) host.ShowNotice(Loc.T("Not every page was read"), reading.Turns.Count == 0 ? text : $"{text} {Turned(reading.Turns.Count)}");
        else if (reading.Turns.Count > 0) host.ShowNotice(Loc.T("Pages turned"), Turned(reading.Turns.Count));
        return result;
    }

    /// <summary>Reads like <see cref="PdfSearchable.ReadAsync"/>, and tries a page that gives no words turned by 90, 180 and 270 degrees. The turns are in quarter turns by 0-based page.</summary>
    internal static async Task<(OcrRead Read, IReadOnlyDictionary<int, int> Turns)> ReadAsync(PdfDocument document, IPageRenderer renderer, ITextRecognizer recognizer,
                                                                                               OcrOptions options, IProgress<OcrProgress>? progress, CancellationToken cancellation,
                                                                                               IReadOnlyList<string>? languages = null)
    {
        var reading = new Reading(renderer, recognizer, languages ?? [options.Language]);
        var read = await PdfSearchable.ReadAsync(document, reading, reading, options, progress, cancellation);
        return (read with { Pages = reading.Pages }, reading.Turns);
    }

    /// <summary>Turns the pages that were read sideways upright, then adds the layers in that frame. Returns the words added; the caller commits.</summary>
    internal static int Write(PdfDocument document, IReadOnlyList<OcrPageWords> pages, IReadOnlyDictionary<int, int> turns, string language)
    {
        foreach (var (page, turn) in turns) PageOperations.Rotate(document, [page], turn * 90);
        return PdfOcrLayer.Add(document, pages, language);
    }

    private static string Turned(int pages) => Loc.Plural(pages, "{0} page was turned upright.", "{0} pages were turned upright.");

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

    // ReadAsync renders and reads one page after the other, so the page drawn last is the one being read.
    private const int MinTurnedWords = 3;

    private sealed class Reading(IPageRenderer inner, ITextRecognizer recognizer, IReadOnlyList<string> languages) : IPageRenderer, ITextRecognizer
    {
        private int _last;
        public List<OcrPageWords> Pages { get; } = [];
        public Dictionary<int, int> Turns { get; } = [];

        public PdfRgbaImage? Render(int pageIndex, double dpi)
        {
            _last = pageIndex;
            return inner.Render(pageIndex, dpi);
        }

        public async Task<IReadOnlyList<OcrWord>> RecognizeAsync(PdfRgbaImage image, string language, CancellationToken cancellation = default)
        {
            var words = await Best(image, cancellation).ConfigureAwait(false);
            int turn = 0;
            var read = image;
            if (words.Count == 0 && !PageInk.IsBlank(image))
            {
                for (int t = 1; t < 4; t++)
                {
                    var turned = WindowsOcr.Turn(image, t);
                    var found = await Best(turned, cancellation).ConfigureAwait(false);
                    if (found.Count > words.Count) (words, turn, read) = (found, t, turned);
                }
                if (words.Count < MinTurnedWords) (words, turn, read) = (Array.Empty<OcrWord>(), 0, image);
            }
            if (turn != 0) Turns[_last] = turn;
            Pages.Add(new OcrPageWords(_last, words, read.Width, read.Height));
            return words;
        }

        // Windows reads one language at a time, so each is tried and the reading with the most words stays.
        private async Task<IReadOnlyList<OcrWord>> Best(PdfRgbaImage image, CancellationToken cancellation)
        {
            IReadOnlyList<OcrWord>? best = null;
            foreach (var tag in languages)
            {
                var words = await recognizer.RecognizeAsync(image, tag, cancellation).ConfigureAwait(false);
                if (best is null || words.Count > best.Count) best = words;
            }
            return best ?? [];
        }
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
