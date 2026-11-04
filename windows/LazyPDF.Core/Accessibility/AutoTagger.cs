namespace LazyPDF.Core;

/// <param name="Language">Written as the document's /Lang when it has none, a BCP 47 tag such as "en-US".</param>
public sealed record AutoTagOptions(string? Language = null);

/// <summary>A figure the tagger made, for the person to give a description.</summary>
public sealed record TaggedFigure(int PageIndex, PdfReference Reference);

/// <param name="AlreadyTagged">The document had a structure tree and was left as it was.</param>
/// <param name="Pages">Pages that were tagged.</param>
/// <param name="SkippedPages">Pages left without tags: shared or unreadable content streams, or more content than the interpreter runs.</param>
/// <param name="Artifacts">Marked-content sequences written as /Artifact: paths, shadings, unclaimed images and text.</param>
public sealed record AutoTagResult(
    bool AlreadyTagged, int Pages, int SkippedPages, int Headings, int Paragraphs, int Lists, int Tables, int Figures, int Artifacts,
    IReadOnlyList<TaggedFigure> FiguresWithoutAlt);

/// <summary>
/// Tags an untagged document from the layout <see cref="TextPage"/> finds (ISO 32000-1 14.8, 14.7.4):
/// headings, paragraphs, lists, tables and figures become structure elements in reading order, their
/// content is wrapped in /MCID sequences, and running headers, footers, page numbers and drawing
/// become artifacts. It writes /StructTreeRoot with its parent tree, /MarkInfo, /StructParents and
/// /Tabs /S. Nothing is saved; the caller commits the document.
/// </summary>
public static class AutoTagger
{
    public static AutoTagResult Tag(PdfDocument document, AutoTagOptions? options = null, CancellationToken cancel = default)
    {
        if (document.IsTagged || document.Dict(document.Catalog, "StructTreeRoot") is not null)
        {
            return new AutoTagResult(true, 0, 0, 0, 0, 0, 0, 0, 0, []);
        }

        var interpreter = new ContentInterpreter(document);
        var stats = TagStats.Collect(document, interpreter, cancel);
        var shared = TagSession.SharedStreams(document);

        var layouts = new List<TagPage?>();
        foreach (var page in document.Pages)
        {
            cancel.ThrowIfCancellationRequested();
            var text = TextPage.Create(interpreter, page);
            var scan = TagScan.Run(interpreter, page);
            bool usable = !text.IsTruncated && !scan.Truncated && TagSession.Streams(document, page).All(s => shared[s] == 1);
            layouts.Add(usable ? TagLayout.Build(document, page, text, scan, stats) : null);
        }

        var session = new TagSession(document, layouts);
        for (int i = 0; i < layouts.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            session.Tag(document.Pages[i], layouts[i]);
        }

        if (session.Skipped == layouts.Count && layouts.Count > 0)
        {
            return new AutoTagResult(false, 0, session.Skipped, 0, 0, 0, 0, 0, 0, []);
        }
        session.Write();
        if (!string.IsNullOrEmpty(options?.Language) && string.IsNullOrEmpty(PdfText.Read(document, document.Catalog, "Lang")))
        {
            document.Catalog["Lang"] = PdfText.ToObject(options.Language);
        }
        return session.Result(layouts.Count);
    }
}
