namespace LazyPDF.Core;

/// <summary>
/// Adds watermarks, backgrounds, headers, footers and Bates numbers to a document as page content,
/// and finds them again. Everything a run adds is marked as an artifact (ISO 32000-1 14.8.2.2) and
/// as that run's own through a /LazyPDF key in the content streams, so <see cref="List()"/>,
/// <c>Update</c> and <see cref="Remove"/> work on it later, in the same session or after a save.
/// A run is one id across the pages it covers. Nothing is saved here; the caller saves the document.
/// </summary>
/// <param name="fonts">Where font files come from for text a Standard 14 font cannot draw.</param>
public sealed partial class PdfStamper(PdfDocument document, IFontSource? fonts = null)
{
    /// <exception cref="ArgumentException">Neither or both of text and image.</exception>
    /// <exception cref="InvalidOperationException">No font can draw the text (<see cref="StampsText.NoFont"/>).</exception>
    public StampRun AddWatermark(WatermarkSpec spec) => Watermark(NextId(), spec);

    public StampRun AddBackground(BackgroundSpec spec) => Background(NextId(), spec);

    public StampRun AddHeaderFooter(HeaderFooterSpec spec) => HeaderFooter(NextId(), spec);

    /// <summary>Replaces run <paramref name="id"/> with a new one under the same id; adds it when there is no such run.</summary>
    public StampRun Update(int id, WatermarkSpec spec) => Replace(id, i => Watermark(i, spec));

    public StampRun Update(int id, BackgroundSpec spec) => Replace(id, i => Background(i, spec));

    public StampRun Update(int id, HeaderFooterSpec spec) => Replace(id, i => HeaderFooter(i, spec));

    /// <summary>The runs on the document, by id.</summary>
    public IReadOnlyList<StampInfo> List() => Collect(document.Pages);

    public IReadOnlyList<StampInfo> List(PdfPage page) => Collect([page]);

    /// <summary>Takes a run off every page; returns the number of pages it was on.</summary>
    public int Remove(int id)
    {
        int pages = 0;
        var uses = StampStreams.CountUses(document);
        foreach (var page in document.Pages)
        {
            if (!StampStreams.Remove(document, page, id, uses)) continue;
            StampStreams.RemoveResources(document, page, id);
            pages++;
        }
        StampLayers.Remove(document, id);
        return pages;
    }

    /// <summary>Removes every run; returns how many there were.</summary>
    public int RemoveAll()
    {
        var ids = List().Select(s => s.Id).ToList();
        foreach (int id in ids) Remove(id);
        return ids.Count;
    }

    // The new run is tried under a spare id first, so that a spec that cannot be drawn leaves the old run alone.
    private StampRun Replace(int id, Func<int, StampRun> add)
    {
        int probe = NextId();
        try
        {
            add(probe);
        }
        catch
        {
            Remove(probe);
            throw;
        }
        Remove(probe);
        Remove(id);
        return add(id);
    }

    private List<StampInfo> Collect(IReadOnlyList<PdfPage> pages)
    {
        var runs = new SortedDictionary<int, (StampKind Kind, string? Label, bool Behind, List<int> Pages)>();
        foreach (var page in pages)
        {
            foreach (var found in StampStreams.Scan(document, page))
            {
                if (!runs.TryGetValue(found.Id, out var run)) runs[found.Id] = run = (found.Kind, found.Label, found.Behind, []);
                run.Pages.Add(page.Index);
            }
        }
        return [.. runs.Select(r => new StampInfo(r.Key, r.Value.Kind, r.Value.Label, r.Value.Behind, r.Value.Pages))];
    }

    private int NextId() => StampStreams.Spare(document.Pages.SelectMany(p => StampStreams.Scan(document, p)).Select(f => f.Id).ToHashSet());

    private List<int> Targets(IReadOnlyList<int>? pages) => pages is null
        ? [.. Enumerable.Range(0, document.Pages.Count)]
        : [.. pages.Where(i => i >= 0 && i < document.Pages.Count).Distinct().Order()];

    private PdfDrawFont Font(string family, FontStyles style, IEnumerable<string> texts) =>
        new PdfFontEmbedder(document, fonts).Add(family, style, texts) ?? throw new InvalidOperationException(StampsText.NoFont);

    private PdfReference? Layer(int id, string? name) => string.IsNullOrEmpty(name) ? null : StampLayers.Add(document, id, name);

    private PdfReference? Opacity(double opacity)
    {
        if (opacity >= 1) return null;
        var state = new PdfDictionary();
        state["Type"] = new PdfName("ExtGState");
        state["ca"] = state["CA"] = new PdfNumber(Math.Max(0, opacity));
        return document.Add(state);
    }

    /// <summary>Puts what the page's content refers to under the run's names and adds the content.</summary>
    private void Finish(PdfPage page, StampCanvas canvas, int id, StampKind kind, string? label, bool behind,
                        PdfReference? font, PdfReference? image, PdfReference? state, PdfReference? layer)
    {
        var resources = ContentResources.ForEdit(document, page);
        if (font is not null) StampStreams.Register(document, resources, "Font", StampStreams.FontName(id), font);
        if (image is not null) StampStreams.Register(document, resources, "XObject", StampStreams.ImageName(id), image);
        if (state is not null) StampStreams.Register(document, resources, "ExtGState", StampStreams.StateName(id), state);
        if (layer is not null) StampStreams.Register(document, resources, "Properties", StampStreams.LayerResourceName(id), layer);
        StampStreams.Add(document, page, canvas.ToArray(), id, kind, label, behind);
    }
}
