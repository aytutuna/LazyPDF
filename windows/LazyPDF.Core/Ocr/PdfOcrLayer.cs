namespace LazyPDF.Core;

/// <summary>The recognized words of one page and the size of the picture they were found in.</summary>
public sealed record OcrPageWords(int PageIndex, IReadOnlyList<OcrWord> Words, int PixelWidth, int PixelHeight);

/// <summary>A word of a page's text layer. <paramref name="Index"/> counts words from 0 in reading order; <paramref name="Box"/> is on the page as shown.</summary>
public sealed record OcrLayerWord(int Index, string Text, DisplayRect Box);

/// <summary>
/// The invisible text layer that makes a scanned page searchable: the words in render mode 3
/// (ISO 32000-1 9.3.6) in a font whose only glyph draws nothing, set on the boxes where the
/// recognizer found them. The layer is one content stream per page, first in /Contents and wrapped
/// in q..Q, carrying a /LazyPDFOcr key; that key is what <see cref="Has"/>, <see cref="Remove"/>
/// and <see cref="Add"/> look for, so a layer by another tool is neither found nor removed.
/// Changes are made to the open document in memory; the caller commits them.
/// </summary>
public static class PdfOcrLayer
{
    /// <summary>Words past this many on a page are ignored.</summary>
    public const int MaxWords = 5000;

    /// <summary>
    /// Writes the layer of each page, replacing the one it has. A page whose words come to nothing
    /// ends up without a layer. One font serves all the pages of a call. Returns the words placed
    /// (empty text and boxes without area or position are left out, and words past <see cref="MaxWords"/> on a page).
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">A page index outside the document, or a picture size of zero.</exception>
    public static int Add(PdfDocument document, IReadOnlyList<OcrPageWords> pages, string language)
    {
        var layouts = new List<(PdfPage Page, PageGeometry Geometry, List<List<PlacedWord>> Lines)>();
        foreach (var entry in pages)
        {
            if (entry.PageIndex < 0 || entry.PageIndex >= document.Pages.Count) throw new ArgumentOutOfRangeException(nameof(pages));
            if (entry.PixelWidth <= 0 || entry.PixelHeight <= 0) throw new ArgumentOutOfRangeException(nameof(pages));
            var page = document.Pages[entry.PageIndex];
            var geometry = new PageGeometry(page);
            layouts.Add((page, geometry, OcrLayerContent.Layout(entry.Words, entry.PixelWidth, entry.PixelHeight, geometry)));
        }

        // Adding objects can fail (the file has no numbers left), so everything that adds one comes before the old layers go.
        var texts = layouts.SelectMany(l => l.Lines).SelectMany(l => l).Select(w => w.Text);
        var codes = GlyphlessCodes.For(texts);
        PdfReference? font = null;
        var streams = new List<PdfReference?>();
        foreach (var (page, geometry, lines) in layouts)
        {
            if (lines.Count == 0)
            {
                streams.Add(null);
                continue;
            }
            font ??= OcrLayerContent.AddFont(document, codes);
            streams.Add(OcrLayerContent.AddStream(document, OcrLayerContent.Build(lines, geometry, UnitOf(page), codes), language));
        }

        foreach (var (page, _, _) in layouts) Remove(document, page);
        int count = 0;
        for (int i = 0; i < layouts.Count; i++)
        {
            if (streams[i] is not { } stream) continue;
            var page = layouts[i].Page;
            PrivateFonts(document, page, create: true)![OcrLayerContent.FontName] = font!;
            var items = Contents(document, page);
            items.Insert(0, stream);
            page.Dictionary["Contents"] = new PdfArray(items);
            count += layouts[i].Lines.Sum(l => l.Count);
        }
        return count;
    }

    /// <summary>True when the page has a layer written by <see cref="Add"/>.</summary>
    public static bool Has(PdfDocument document, PdfPage page) => LayerStreams(document, page).Count > 0;

    /// <summary>The language tag the layer was written with, or null without a layer.</summary>
    public static string? Language(PdfDocument document, PdfPage page)
    {
        var stream = LayerStreams(document, page).FirstOrDefault();
        return stream is null ? null : LanguageOf(document, stream);
    }

    private static string? LanguageOf(PdfDocument document, PdfStream stream) =>
        document.Resolve(document.Dict(stream.Dictionary, OcrLayerContent.Key)?["Lang"]) is PdfString s ? System.Text.Encoding.ASCII.GetString(s.Bytes) : null;

    /// <summary>Takes the layer off the page and its font out of the page's resources. Returns false when there was none.</summary>
    public static bool Remove(PdfDocument document, PdfPage page)
    {
        var layers = LayerStreams(document, page);
        if (layers.Count == 0) return false;
        // A page copied by Duplicate shares the stream, so the object stays.
        var items = Contents(document, page);
        items.RemoveAll(i => document.Resolve(i) is PdfStream s && layers.Contains(s));
        page.Dictionary["Contents"] = new PdfArray(items);
        PrivateFonts(document, page, create: false)?.Remove(OcrLayerContent.FontName);
        return true;
    }

    /// <summary>The words of the layer in the order they were written, boxes on the page as shown. Empty without a layer.</summary>
    public static IReadOnlyList<OcrLayerWord> Words(PdfDocument document, PdfPage page)
    {
        var geometry = new PageGeometry(page);
        var words = new List<OcrLayerWord>();
        foreach (var stream in LayerStreams(document, page))
        {
            foreach (var word in OcrLayerContent.Read(document, page, stream, geometry).SelectMany(l => l))
            {
                words.Add(new OcrLayerWord(words.Count, word.Text, Bounds(word)));
            }
        }
        return words;
    }

    // A turned word is an upright box at its baseline start, turned by Angle; the box shown covers the turned word.
    private static DisplayRect Bounds(PlacedWord word)
    {
        if (word.Angle == 0) return new DisplayRect(word.X, word.Y, word.Width, word.Height);
        double cos = Math.Cos(word.Angle), sin = Math.Sin(word.Angle);
        double px = word.X, py = word.Y + word.Height;
        double ex = word.Width * cos, ey = -word.Width * sin;
        double ux = -word.Height * sin, uy = -word.Height * cos;
        double left = px + Math.Min(0, Math.Min(ex, Math.Min(ux, ex + ux)));
        double right = px + Math.Max(0, Math.Max(ex, Math.Max(ux, ex + ux)));
        double top = py + Math.Min(0, Math.Min(ey, Math.Min(uy, ey + uy)));
        double bottom = py + Math.Max(0, Math.Max(ey, Math.Max(uy, ey + uy)));
        return new DisplayRect(left, top, right - left, bottom - top);
    }

    /// <summary>
    /// Changes the text of word <paramref name="index"/> (as <see cref="Words"/> numbers them); the
    /// box stays. Empty text removes the word. The font is replaced only when the text has a
    /// character beyond the BMP that the font does not carry yet.
    /// </summary>
    /// <exception cref="ArgumentOutOfRangeException">No such word.</exception>
    public static void Correct(PdfDocument document, PdfPage page, int index, string text)
    {
        var shown = new PageGeometry(page);
        int first = 0;
        foreach (var stream in LayerStreams(document, page))
        {
            var geometry = OcrLayerContent.WrittenIn(document, page, stream, shown);
            var lines = OcrLayerContent.Read(document, page, stream, geometry);
            int count = lines.Sum(l => l.Count);
            if (index >= first + count)
            {
                first += count;
                continue;
            }
            Change(lines, index - first, OcrLayerContent.Clean(text));
            Rewrite(document, page, stream, lines, geometry);
            return;
        }
        throw new ArgumentOutOfRangeException(nameof(index));
    }

    private static void Change(List<List<PlacedWord>> lines, int index, string text)
    {
        if (index < 0) throw new ArgumentOutOfRangeException(nameof(index));
        foreach (var line in lines)
        {
            if (index >= line.Count)
            {
                index -= line.Count;
                continue;
            }
            if (text.Length == 0) line.RemoveAt(index);
            else line[index] = line[index] with { Text = text };
            lines.RemoveAll(l => l.Count == 0);
            return;
        }
    }

    private static void Rewrite(PdfDocument document, PdfPage page, PdfStream stream, List<List<PlacedWord>> lines, PageGeometry geometry)
    {
        var fonts = PrivateFonts(document, page, create: true)!;
        var texts = lines.SelectMany(l => l).Select(w => w.Text).ToList();
        var current = OcrLayerContent.FontOf(document, page, OcrLayerContent.FontName);
        var known = current is null ? null : GlyphlessCodes.From(current);
        // The font serves every layer stream of the page, so a replacement keeps the characters the old one had at their codes.
        var codes = GlyphlessCodes.For((known?.Supplementary ?? []).Select(char.ConvertFromUtf32).Concat(texts));
        // Codes of characters beyond the BMP depend on the font, so a font that lacks one of them is replaced.
        if (known is not null && texts.All(known.Covers)) codes = known;
        else fonts[OcrLayerContent.FontName] = OcrLayerContent.AddFont(document, codes);
        // A new stream, not new data in the old one: a duplicated page shares the old stream.
        var items = Contents(document, page);
        items[items.FindIndex(i => document.Resolve(i) == stream)] =
            OcrLayerContent.AddStream(document, OcrLayerContent.Build(lines, geometry, UnitOf(page), codes), LanguageOf(document, stream) ?? "");
        page.Dictionary["Contents"] = new PdfArray(items);
    }

    private static double UnitOf(PdfPage page) => page.UserUnit > 0 ? page.UserUnit : 1;

    private static List<PdfObject> Contents(PdfDocument document, PdfPage page) => document.Resolve(page.Dictionary["Contents"]) switch
    {
        PdfStream => [page.Dictionary["Contents"]!],
        PdfArray array => [.. array.Items],
        _ => [],
    };

    private static List<PdfStream> LayerStreams(PdfDocument document, PdfPage page) =>
        [.. Contents(document, page).Select(document.Resolve).OfType<PdfStream>().Where(s => s.Dictionary.ContainsKey(OcrLayerContent.Key))];

    // The page's /Font dictionary as a copy of its own, so that a resources dictionary shared between pages is left alone.
    private static PdfDictionary? PrivateFonts(PdfDocument document, PdfPage page, bool create)
    {
        if (!create && document.Dict(page.Resources, "Font")?.ContainsKey(OcrLayerContent.FontName) != true) return null;
        var resources = ContentResources.ForEdit(document, page);
        if (page.Dictionary["Resources"] is PdfReference)
        {
            resources = resources.Copy();
            page.Dictionary["Resources"] = resources;
        }
        var fonts = document.Dict(resources, "Font")?.Copy() ?? new PdfDictionary();
        resources["Font"] = fonts;
        return fonts;
    }
}
