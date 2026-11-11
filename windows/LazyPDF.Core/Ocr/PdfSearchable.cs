namespace LazyPDF.Core;

/// <summary>What to do with a page that already has a layer from an earlier run.</summary>
public enum OcrExisting
{
    Skip,
    Replace,
}

/// <param name="Language">A BCP 47 tag, passed to the recognizer.</param>
/// <param name="Dpi">The resolution pages are drawn at for the recognizer, 72 to 600.</param>
/// <param name="Pages">0-based pages to look at; null for all. Out of range and repeated entries are ignored.</param>
/// <param name="Force">Read pages with text a person can see, and pages with an invisible layer from another tool, too.</param>
public sealed record OcrOptions(string Language = "en-US", double Dpi = 300, OcrExisting Existing = OcrExisting.Skip,
                                IReadOnlyList<int>? Pages = null, bool Force = false);

public enum OcrOutcome
{
    /// <summary>The page has a layer now.</summary>
    Added,
    /// <summary>The recognizer found no words. A layer the page had under Replace is gone.</summary>
    NoWords,
    /// <summary>The page was not for OCR.</summary>
    Skipped,
    /// <summary>The renderer could not draw the page.</summary>
    NotRendered,
}

/// <param name="Done">Pages dealt with so far, this one included.</param>
/// <param name="Total">Pages the run looks at.</param>
public sealed record OcrProgress(int PageIndex, int Done, int Total, OcrOutcome Outcome);

public sealed record OcrResult(int Added, int NoWords, int Skipped, int NotRendered, int Words, bool Committed);

/// <summary>What <see cref="PdfSearchable.ReadAsync"/> found: the counts, with no words written and nothing committed, and the words to write. <paramref name="Stopped"/> is true when a cancel ended a read that asked to keep what it had.</summary>
public sealed record OcrRead(OcrResult Result, IReadOnlyList<OcrPageWords> Pages, bool Stopped = false);

/// <summary>The Make searchable action: reads the pages of a document that need it and adds the text layer.</summary>
public static class PdfSearchable
{
    public const double MinDpi = 72;
    public const double MaxDpi = 600;

    /// <summary>
    /// Looks at each page (<see cref="OcrTriage"/>), draws the ones that need reading through
    /// <paramref name="renderer"/>, has <paramref name="recognizer"/> read them and writes the layers
    /// (<see cref="PdfOcrLayer.Add"/>), then commits them as one step of the session. Nothing is
    /// changed until every page has been read, so a cancel leaves the document as it was. The renderer
    /// and the recognizer see pages in the order of the document; a failure in either is thrown as it
    /// is, with the document untouched.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException"><see cref="OcrOptions.Dpi"/> outside 72 to 600.</exception>
    /// <exception cref="OperationCanceledException"/>
    public static async Task<OcrResult> RunAsync(PdfEditSession session, ITextRecognizer recognizer, IPageRenderer renderer,
                                                 OcrOptions options, IProgress<OcrProgress>? progress = null,
                                                 CancellationToken cancellation = default)
    {
        var read = await ReadAsync(session.Document, recognizer, renderer, options, progress, cancellation).ConfigureAwait(false);
        if (read.Pages.Count == 0) return read.Result;
        int words = PdfOcrLayer.Add(session.Document, read.Pages, options.Language);
        return read.Result with { Words = words, Committed = session.Commit(OcrStatusText.Label) };
    }

    /// <summary>
    /// The reading half of <see cref="RunAsync"/>, for a caller that reads a copy of the file on another thread and
    /// writes the layers into the document it shows (<see cref="PdfOcrLayer.Add"/>). <paramref name="document"/> is only read.
    /// With <paramref name="keepPartial"/> a cancel does not throw: the pages finished before it are returned, the one being
    /// read is not, and <see cref="OcrRead.Stopped"/> is true.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException"><see cref="OcrOptions.Dpi"/> outside 72 to 600.</exception>
    /// <exception cref="OperationCanceledException"/>
    public static async Task<OcrRead> ReadAsync(PdfDocument document, ITextRecognizer recognizer, IPageRenderer renderer,
                                                OcrOptions options, IProgress<OcrProgress>? progress = null,
                                                CancellationToken cancellation = default, bool keepPartial = false)
    {
        if (!(options.Dpi >= MinDpi && options.Dpi <= MaxDpi)) throw new ArgumentOutOfRangeException(nameof(options));
        var targets = options.Pages is null
            ? Enumerable.Range(0, document.Pages.Count).ToList()
            : options.Pages.Where(i => i >= 0 && i < document.Pages.Count).Distinct().Order().ToList();

        var interpreter = new ContentInterpreter(document);
        var found = new List<OcrPageWords>();
        int added = 0, noWords = 0, skipped = 0, notRendered = 0, done = 0;
        bool stopped = false;
        try
        {
            foreach (int index in targets)
            {
                cancellation.ThrowIfCancellationRequested();
                var page = document.Pages[index];
                var kind = OcrTriage.Classify(document, page, interpreter);
                OcrOutcome outcome;
                if (!OcrTriage.NeedsOcr(kind, options.Existing == OcrExisting.Replace, options.Force))
                {
                    outcome = OcrOutcome.Skipped;
                    skipped++;
                }
                else if (renderer.Render(index, options.Dpi) is not { } image)
                {
                    outcome = OcrOutcome.NotRendered;
                    notRendered++;
                }
                else
                {
                    var recognized = await recognizer.RecognizeAsync(image, options.Language, cancellation).ConfigureAwait(false);
                    found.Add(new OcrPageWords(index, recognized, image.Width, image.Height));
                    if (OcrLayerContent.Layout(recognized, image.Width, image.Height, new PageGeometry(page)).Count > 0)
                    {
                        outcome = OcrOutcome.Added;
                        added++;
                    }
                    else
                    {
                        outcome = OcrOutcome.NoWords;
                        noWords++;
                    }
                }
                progress?.Report(new OcrProgress(index, ++done, targets.Count, outcome));
            }
        }
        catch (OperationCanceledException) when (keepPartial && cancellation.IsCancellationRequested)
        {
            stopped = true;
        }

        if (!keepPartial) cancellation.ThrowIfCancellationRequested();
        return new OcrRead(new OcrResult(added, noWords, skipped, notRendered, 0, false), found, stopped);
    }
}
