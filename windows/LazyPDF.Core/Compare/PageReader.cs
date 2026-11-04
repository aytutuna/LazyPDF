using System.Security.Cryptography;

namespace LazyPDF.Core;

internal sealed record PageImage(string Hash, PdfRect Bounds);

/// <summary>The words of one page that take part in a comparison, as ids shared by both files.</summary>
internal sealed class PageData(PdfPage page, TextPage text, int[] kept, int[] ids)
{
    public PdfPage Page { get; } = page;
    public TextPage Text { get; } = text;

    /// <summary>Indexes into <see cref="TextPage.Words"/> of the words that count.</summary>
    public int[] Kept { get; } = kept;

    public int[] Ids { get; } = ids;

    public string Word(int token) => Text.Words[Kept[token]].Text;

    public string Words(int from, int count) => string.Join(' ', Enumerable.Range(from, count).Select(Word));

    /// <summary>The boxes of tokens <c>[from, from + count)</c>, one for each stretch of a line.</summary>
    public List<TextQuad> Quads(int from, int count)
    {
        var quads = new List<TextQuad>();
        int k = from;
        while (k < from + count)
        {
            int last = k;
            while (last + 1 < from + count && Kept[last + 1] == Kept[last] + 1) last++;
            quads.AddRange(Text.Quads(new TextRange(Text.Words[Kept[k]].Range.Start, Text.Words[Kept[last]].Range.End)));
            k = last + 1;
        }
        return quads;
    }

    /// <summary>A quad of zero width at the place before token <paramref name="at"/>: the right edge of the word before it, else the left edge of the one at it.</summary>
    public List<TextQuad> Anchor(int at)
    {
        if (at > 0 && Quads(at - 1, 1) is { Count: > 0 } before)
        {
            var q = before[^1];
            return [new TextQuad(q.X1, q.Y1, q.X1, q.Y1, q.X2, q.Y2, q.X2, q.Y2)];
        }
        if (at < Kept.Length && Quads(at, 1) is { Count: > 0 } after)
        {
            var q = after[0];
            return [new TextQuad(q.X0, q.Y0, q.X0, q.Y0, q.X3, q.Y3, q.X3, q.Y3)];
        }
        return [];
    }

    public TextChar FormatChar(int token) => Text.Chars[Text.Words[Kept[token]].Range.Start];
}

/// <summary>Reads the pages of one file as <see cref="PageData"/> and finds the pictures on them.</summary>
internal sealed class PageReader(PdfDocument document, CompareOptions options, Dictionary<string, int> ids)
{
    private const double ZoneFraction = 0.07;
    private readonly TextCache _cache = new(document);
    private readonly ContentInterpreter _interpreter = new(document);
    private readonly Dictionary<PdfStream, string> _hashes = new(ReferenceEqualityComparer.Instance);

    public PdfDocument Document => document;

    public int Count => document.Pages.Count;

    public PageData Load(int index)
    {
        var page = document.Pages[index];
        var text = _cache.Get(index);
        var geometry = options.IgnoreHeaderFooter ? new PageGeometry(page) : null;
        var kept = new List<int>();
        var tokens = new List<int>();
        for (int w = 0; w < text.Words.Count; w++)
        {
            var word = text.Words[w];
            if (word.Text.Length == 0) continue;
            if (geometry is not null)
            {
                var centre = geometry.ToDisplay((word.Bounds.Left + word.Bounds.Right) / 2, (word.Bounds.Bottom + word.Bounds.Top) / 2);
                if (centre.Y < geometry.Height * ZoneFraction || centre.Y > geometry.Height * (1 - ZoneFraction)) continue;
            }
            kept.Add(w);
            tokens.Add(Id(options.IgnoreCase ? word.Text.ToLowerInvariant() : word.Text));
        }
        return new PageData(page, text, [.. kept], [.. tokens]);
    }

    private int Id(string token)
    {
        if (!ids.TryGetValue(token, out int id)) ids[token] = id = ids.Count;
        return id;
    }

    public List<PageImage> Images(PdfPage page)
    {
        var found = new List<PageImage>();
        _interpreter.Run(page, new ImageCollector(this, found));
        return found;
    }

    private string Hash(ImageInfo image)
    {
        byte[] data;
        if (image.Stream is { } stream)
        {
            if (_hashes.TryGetValue(stream, out string? known)) return known;
            data = document.RawData(stream);
        }
        else data = image.Inline?.Data ?? [];
        string hash = $"{image.Width}x{image.Height}:{Convert.ToHexString(SHA256.HashData(data), 0, 12)}";
        if (image.Stream is { } s) _hashes[s] = hash;
        return hash;
    }

    private sealed class ImageCollector(PageReader reader, List<PageImage> found) : ContentVisitor
    {
        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (found.Count < 10_000 && image.Bounds.Width >= 1 && image.Bounds.Height >= 1) found.Add(new PageImage(reader.Hash(image), image.Bounds));
        }
    }
}
