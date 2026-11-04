namespace LazyPDF.Core;

/// <summary>
/// One page of the tree. It reads its dictionary as it is now, so a change to the dictionary shows
/// at once; what a page inherits from its ancestors (ISO 32000-1 7.7.3.4) was taken when the tree
/// was walked.
/// </summary>
public sealed class PdfPage
{
    /// <summary>US Letter, what a viewer shows for a page without a usable /MediaBox.</summary>
    private static readonly PdfRect DefaultBox = new(0, 0, 612, 792);

    // No page has more content than this; the limit is shared by all of its streams.
    private const long MaxContentSize = 256L << 20;

    private readonly PdfDocument _document;
    private readonly PageInheritance _inherited;

    internal PdfPage(PdfDocument document, PdfDictionary dictionary, PdfReference reference, int index, PageInheritance inherited)
    {
        _document = document;
        Dictionary = dictionary;
        Reference = reference;
        Index = index;
        _inherited = inherited;
    }

    public PdfDictionary Dictionary { get; }
    public PdfReference Reference { get; }

    /// <summary>Position in reading order, from 0.</summary>
    public int Index { get; }

    public PdfDictionary? Resources =>
        _document.Dict(Dictionary, "Resources") ?? _document.Resolve(_inherited.Resources) as PdfDictionary;

    /// <summary>The paper: /MediaBox, or US Letter when it is missing or has no area.</summary>
    public PdfRect MediaBox => Box("MediaBox", _inherited.MediaBox) ?? DefaultBox;

    /// <summary>What is shown: /CropBox clipped to the media box; the media box without one.</summary>
    public PdfRect CropBox
    {
        get
        {
            var media = MediaBox;
            if (Box("CropBox", _inherited.CropBox) is not { } crop) return media;
            var clipped = crop.Intersect(media);
            return clipped.IsEmpty ? media : clipped;
        }
    }

    public PdfRect TrimBox => Box("TrimBox", null) ?? CropBox;
    public PdfRect BleedBox => Box("BleedBox", null) ?? CropBox;
    public PdfRect ArtBox => Box("ArtBox", null) ?? CropBox;

    /// <summary>Clockwise degrees the page is turned when shown: 0, 90, 180 or 270 (anything else rounds to the nearest).</summary>
    public int Rotate
    {
        get
        {
            var value = _document.Resolve(Dictionary["Rotate"]) ?? _document.Resolve(_inherited.Rotate);
            if (value is not PdfNumber number) return 0;
            int quarters = (int)Math.Round(Math.Clamp(number.Value, -1e6, 1e6) / 90);
            return (quarters % 4 + 4) % 4 * 90;
        }
    }

    /// <summary>User space units per point (ISO 32000-1 14.11.2.3); 1 unless /UserUnit is a positive number.</summary>
    public double UserUnit =>
        _document.Number(Dictionary, "UserUnit") is > 0 and var unit && double.IsFinite(unit) ? unit : 1;

    /// <summary>
    /// The page's content streams, decoded and joined with a newline so that no token runs into
    /// the next stream (7.8.2). A stream that cannot be read is left out and noted in the
    /// document's repairs.
    /// </summary>
    public byte[] Contents()
    {
        var parts = new List<byte[]>();
        long room = MaxContentSize;
        var contents = _document.Resolve(Dictionary["Contents"]);
        var streams = contents is PdfArray array ? array.Items : [contents ?? PdfNull.Instance];
        foreach (var item in streams)
        {
            if (_document.Resolve(item) is not PdfStream stream) continue;
            try
            {
                byte[] part = _document.Data(stream, room);
                room = Math.Max(0, room - part.Length - 1);
                parts.Add(part);
            }
            catch (PdfReadException e)
            {
                _document.AddRepair($"Page {Index + 1}: a content stream could not be read ({e.Message})");
            }
        }
        long total = parts.Count > 0 ? parts.Count - 1 : 0;
        foreach (var part in parts) total += part.Length;
        var result = new byte[total];
        int at = 0;
        for (int i = 0; i < parts.Count; i++)
        {
            if (i > 0) result[at++] = (byte)'\n';
            parts[i].CopyTo(result, at);
            at += parts[i].Length;
        }
        return result;
    }

    private PdfRect? Box(string key, PdfObject? inherited) =>
        _document.Rect(Dictionary[key]) ?? _document.Rect(inherited);
}

/// <summary>What a page takes from the nodes above it when it has no value of its own.</summary>
internal readonly record struct PageInheritance(PdfObject? Resources, PdfObject? MediaBox, PdfObject? CropBox, PdfObject? Rotate);
