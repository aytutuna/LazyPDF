namespace LazyPDF.Core;

/// <summary>
/// How a stamp sits in a page's /Contents. Each run adds one stream per page carrying a /LazyPDF
/// dictionary (the run's id, kind, label and whether it is behind). A stamp in front of the page is
/// kept apart from the page's own content by a pair of marked streams around it, built from how
/// unbalanced the content is: the first opens as many q as the content may pop and the second
/// closes what it leaves open, so the stamp starts and ends in a clean graphics state whatever the
/// page does (ISO 32000-1 8.4.2). Stamps behind the page need none, they close themselves.
/// </summary>
internal static class StampStreams
{
    public const string Key = "LazyPDF";
    private const int MaxDepth = 1000;

    public static string Prefix(int id) => $"LPS{id}_";
    public static string FontName(int id) => Prefix(id) + "F";
    public static string ImageName(int id) => Prefix(id) + "I";
    public static string StateName(int id) => Prefix(id) + "G";
    public static string LayerResourceName(int id) => Prefix(id) + "P";

    /// <summary>The run id in a marker; one outside the range of an int is not one this code wrote, and is left alone.</summary>
    public static int? IdOf(PdfDocument document, PdfDictionary marker) =>
        document.Integer(marker, "Id") is >= int.MinValue and <= int.MaxValue and var id ? (int)id : null;

    /// <summary>An id above every one in use, or the lowest free one when there is none above.</summary>
    public static int Spare(ICollection<int> used)
    {
        int max = used.DefaultIfEmpty(0).Max();
        if (max < int.MaxValue) return max + 1;
        int id = 1;
        while (used.Contains(id)) id++;
        return id;
    }

    public readonly record struct Found(int Id, StampKind Kind, string? Label, bool Behind);

    public static List<PdfObject> Contents(PdfDocument document, PdfPage page)
    {
        var value = page.Dictionary["Contents"];
        return document.Resolve(value) switch
        {
            PdfStream => [value!],
            PdfArray array => [.. array.Items],
            _ => [],
        };
    }

    private static PdfDictionary? MarkerOf(PdfDocument document, PdfObject item) =>
        document.Resolve(item) is PdfStream stream ? document.Dict(stream.Dictionary, Key) : null;

    /// <summary>The runs on the page in content order.</summary>
    public static List<Found> Scan(PdfDocument document, PdfPage page)
    {
        var found = new List<Found>();
        foreach (var item in Contents(document, page))
        {
            if (MarkerOf(document, item) is not { } marker || IdOf(document, marker) is not { } id) continue;
            // The name as written; Enum.TryParse would also take numbers, lists and spaces.
            var kind = Enum.TryParse<StampKind>(document.Name(marker, "Kind"), out var k) && Enum.GetName(k) == document.Name(marker, "Kind") ? k : StampKind.Watermark;
            string? label = document.Resolve(marker["Label"]) is PdfString s ? PdfText.Decode(s.Bytes) : null;
            found.Add(new Found(id, kind, label, document.Bool(marker, "Back") == true));
        }
        return found;
    }

    public static void Add(PdfDocument document, PdfPage page, byte[] content, int id, StampKind kind, string? label, bool behind)
    {
        var marker = new PdfDictionary();
        marker["Id"] = new PdfNumber(id);
        marker["Kind"] = new PdfName(kind.ToString());
        if (!string.IsNullOrEmpty(label)) marker["Label"] = PdfText.ToObject(label);
        if (behind) marker["Back"] = new PdfBoolean(true);
        var reference = AddStream(document, content, marker);

        var items = Contents(document, page);
        if (behind)
        {
            items.Insert(LeadingBack(document, items), reference);
        }
        else
        {
            if (!items.Any(i => MarkerOf(document, i)?["Wrap"] is not null)) Wrap(document, page, items);
            items.Add(reference);
        }
        page.Dictionary["Contents"] = new PdfArray(items);
    }

    /// <summary>Takes the run off the page; returns false when it was not there.</summary>
    public static bool Remove(PdfDocument document, PdfPage page, int id, Dictionary<int, int> uses)
    {
        var items = Contents(document, page);
        int before = items.Count;
        items.RemoveAll(item => Drop(document, item, id, uses));
        if (items.Count == before) return false;
        // Without a stamp in front the wrapper has nothing to keep apart.
        bool front = items.Any(i => MarkerOf(document, i) is { } m && IdOf(document, m) is not null && document.Bool(m, "Back") != true);
        if (!front) items.RemoveAll(item => Drop(document, item, null, uses));
        page.Dictionary["Contents"] = new PdfArray(items);
        return true;
    }

    /// <summary>Deletes the stream when it belongs to the run (the wrapper when <paramref name="id"/> is null).</summary>
    private static bool Drop(PdfDocument document, PdfObject item, int? id, Dictionary<int, int> uses)
    {
        if (MarkerOf(document, item) is not { } marker || item is not PdfReference reference) return false;
        bool mine = id is null ? marker["Wrap"] is not null : IdOf(document, marker) == id;
        // A duplicated page shares its stamp streams: they are freed with the last page that lists them.
        if (!mine) return false;
        int left = uses.GetValueOrDefault(reference.Number, 1) - 1;
        if (left <= 0) document.Delete(reference.Number);
        else uses[reference.Number] = left;
        return true;
    }

    /// <summary>How many pages list each stamp stream.</summary>
    public static Dictionary<int, int> CountUses(PdfDocument document)
    {
        var uses = new Dictionary<int, int>();
        foreach (var page in document.Pages)
        {
            foreach (var item in Contents(document, page).OfType<PdfReference>().DistinctBy(r => r.Number))
            {
                if (MarkerOf(document, item) is not null) uses[item.Number] = uses.GetValueOrDefault(item.Number) + 1;
            }
        }
        return uses;
    }

    public static void RemoveResources(PdfDocument document, PdfPage page, int id)
    {
        if (document.Dict(page.Dictionary, "Resources") is not { } resources) return;
        string prefix = Prefix(id);
        foreach (string category in (ReadOnlySpan<string>)["Font", "XObject", "ExtGState", "Properties"])
        {
            if (document.Dict(resources, category) is not { } entries) continue;
            foreach (string name in entries.Entries.Select(e => e.Key).Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).ToList()) entries.Remove(name);
        }
    }

    public static void Register(PdfDocument document, PdfDictionary resources, string category, string name, PdfObject value)
    {
        var entries = document.Dict(resources, category);
        if (entries is null)
        {
            entries = new PdfDictionary();
            resources[category] = entries;
        }
        entries[name] = value;
    }

    private static PdfReference AddStream(PdfDocument document, byte[] content, PdfDictionary marker)
    {
        var dictionary = new PdfDictionary();
        dictionary[Key] = marker;
        return document.Add(new PdfStream(dictionary, content));
    }

    private static int LeadingBack(PdfDocument document, List<PdfObject> items)
    {
        int n = 0;
        while (n < items.Count && MarkerOf(document, items[n]) is { } m && document.Bool(m, "Back") == true) n++;
        return n;
    }

    private static void Wrap(PdfDocument document, PdfPage page, List<PdfObject> items)
    {
        int depth = 0, lowest = 0, marked = 0;
        bool text = false;
        foreach (var operation in ContentParser.Parse(page.Contents()))
        {
            switch (operation.Operator)
            {
                case "q": depth++; break;
                case "Q": lowest = Math.Min(lowest, --depth); break;
                case "BT": text = true; break;
                case "ET": text = false; break;
                case "BMC" or "BDC": marked++; break;
                case "EMC": marked = Math.Max(0, marked - 1); break;
            }
        }
        // A Q the content has no q for pops ours, so open enough that none of them can run dry.
        int opened = Math.Clamp(1 - lowest, 1, MaxDepth);
        var close = new ContentWriter();
        if (text) close.EndText();
        for (int i = 0; i < Math.Min(marked, MaxDepth); i++) close.EndMarked();
        for (int i = Math.Clamp(opened + depth, 0, MaxDepth); i > 0; i--) close.Restore();

        var open = new ContentWriter();
        for (int i = 0; i < opened; i++) open.Save();
        items.Insert(LeadingBack(document, items), AddStream(document, open.ToArray(), WrapMarker("Open")));
        items.Add(AddStream(document, close.ToArray(), WrapMarker("Close")));
    }

    private static PdfDictionary WrapMarker(string part)
    {
        var marker = new PdfDictionary();
        marker["Wrap"] = new PdfName(part);
        return marker;
    }
}
