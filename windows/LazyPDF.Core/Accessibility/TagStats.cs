namespace LazyPDF.Core;

/// <summary>What is true of the whole document and decides how each page is read: the body text size and the lines that repeat as running headers and footers.</summary>
internal sealed class TagStats
{
    public double BodySize { get; private set; } = 10;
    public bool BodyBold { get; private set; }

    /// <summary>Band and folded text of lines that repeat on enough pages to be a header or footer.</summary>
    public HashSet<string> Repeated { get; } = [];

    public static TagStats Collect(PdfDocument document, ContentInterpreter interpreter, CancellationToken cancel)
    {
        var stats = new TagStats();
        var sizes = new Dictionary<double, (int Glyphs, int Bold)>();
        var seen = new Dictionary<string, int>();
        foreach (var page in document.Pages)
        {
            cancel.ThrowIfCancellationRequested();
            var text = TextPage.Create(interpreter, page);
            var geometry = new PageGeometry(page);
            var onPage = new HashSet<string>();
            foreach (var source in text.Lines)
            {
                var line = new TagLine(text, source, geometry);
                if (line.Size > 0)
                {
                    var (glyphs, bold) = sizes.GetValueOrDefault(line.Size);
                    sizes[line.Size] = (glyphs + line.Text.Length, bold + (line.Bold ? line.Text.Length : 0));
                }
                if (TagText.Band(line, geometry.Height) is { } band && TagText.Signature(line.Text) is { } signature) onPage.Add(band + "|" + signature);
            }
            foreach (string key in onPage) seen[key] = seen.GetValueOrDefault(key) + 1;
        }

        if (sizes.Count > 0)
        {
            var body = sizes.MaxBy(s => s.Value.Glyphs);
            stats.BodySize = body.Key;
            stats.BodyBold = body.Value.Bold * 2 > body.Value.Glyphs;
        }
        int pages = document.Pages.Count;
        int needed = pages < 3 ? 2 : (pages + 1) / 2;
        foreach (var (key, count) in seen)
        {
            if (count >= needed) stats.Repeated.Add(key);
        }
        return stats;
    }
}
