using System.Text;

namespace LazyPDF.Core;

// Destinations (ISO 32000-1 12.3.2) as far as moving pages needs them: which page an explicit or
// named one points at, and taking named ones out. Outlines and links come back here to ask.
internal sealed class PageDestinations(PdfDocument document)
{
    private const int MaxTreeNodes = 100_000;
    private const int MaxTreeDepth = 32;

    private Dictionary<string, PdfObject>? _table;

    /// <summary>The page an explicit destination (an array, or a dictionary with /D) points at; null for anything else, including a page number of a remote file.</summary>
    public static PdfReference? PageOf(PdfDocument document, PdfObject? destination)
    {
        var value = document.Resolve(destination);
        if (value is PdfDictionary dictionary) value = document.Resolve(dictionary["D"]);
        return value is PdfArray { Items.Count: > 0 } array && array.Items[0] is PdfReference page ? page : null;
    }

    /// <summary>The destination a name or string stands for, from the catalog's /Dests or the /Names tree; null when there is none.</summary>
    public PdfObject? Lookup(PdfObject? key)
    {
        string? text = document.Resolve(key) switch
        {
            PdfName name => name.Value,
            PdfString @string => Encoding.Latin1.GetString(@string.Bytes),
            _ => null,
        };
        return text is not null && Table().TryGetValue(text, out var found) ? found : null;
    }

    /// <summary>The page a /Dest value points at, a name resolved through the document's tables.</summary>
    public PdfReference? PageOfAny(PdfObject? destination) =>
        document.Resolve(destination) is PdfName or PdfString ? PageOf(document, Lookup(destination)) : PageOf(document, destination);

    /// <summary>Takes out every named destination whose value <paramref name="dead"/> says is gone. A leaf of the tree may end up with no names.</summary>
    public void RemoveWhere(Func<PdfObject?, bool> dead)
    {
        if (document.Dict(document.Catalog, "Dests") is { } dictionary)
        {
            foreach (string key in dictionary.Entries.Select(e => e.Key).Distinct().ToList())
            {
                if (dead(dictionary[key])) dictionary.Remove(key);
            }
        }
        var leaves = new HashSet<PdfArray>(ReferenceEqualityComparer.Instance);
        VisitTree((names, _) =>
        {
            leaves.Add(names);
            return true;
        });
        foreach (var names in leaves)
        {
            var kept = new List<PdfObject>();
            for (int i = 0; i + 1 < names.Items.Count; i += 2)
            {
                if (dead(names.Items[i + 1])) continue;
                kept.Add(names.Items[i]);
                kept.Add(names.Items[i + 1]);
            }
            if (kept.Count == names.Items.Count) continue;
            names.Items.Clear();
            names.Items.AddRange(kept);
        }
        if (leaves.Count > 0 && document.Dict(document.Dict(document.Catalog, "Names"), "Dests") is { } root) Limits(root, true, 0);
    }

    // 7.9.6: a node's /Limits are its least and greatest key. A leaf left without names goes from its parent.
    private (PdfString Low, PdfString High)? Limits(PdfDictionary node, bool isRoot, int depth)
    {
        (PdfString Low, PdfString High)? range = null;
        if (document.Array(node, "Names") is { } names)
        {
            var keys = names.Items.Where((_, i) => i % 2 == 0).Select(k => document.Resolve(k)).OfType<PdfString>().ToList();
            if (keys.Count > 0) range = (keys[0], keys[^1]);
        }
        if (depth < MaxTreeDepth && document.Array(node, "Kids") is { } kids)
        {
            foreach (var kid in kids.Items.ToList())
            {
                var child = document.Resolve(kid) as PdfDictionary;
                var inner = child is null ? null : Limits(child, false, depth + 1);
                if (inner is null)
                {
                    kids.Items.Remove(kid);
                    continue;
                }
                range = (range?.Low ?? inner.Value.Low, inner.Value.High);
            }
        }
        if (!isRoot && range is { } r) node["Limits"] = new PdfArray([r.Low, r.High]);
        return range;
    }

    private Dictionary<string, PdfObject> Table()
    {
        if (_table is not null) return _table;
        _table = [];
        if (document.Dict(document.Catalog, "Dests") is { } dictionary)
        {
            foreach (var (key, value) in dictionary.Entries) _table[key] = value;
        }
        VisitTree((_, pair) =>
        {
            _table.TryAdd(pair.Key, pair.Value);
            return true;
        });
        return _table;
    }

    // The pairs of the /Names /Dests tree. The visitor gets the leaf's /Names array and the pair; false stops the walk.
    private void VisitTree(Func<PdfArray, KeyValuePair<string, PdfObject>, bool> visit)
    {
        var root = document.Dict(document.Dict(document.Catalog, "Names"), "Dests");
        if (root is null) return;
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        int nodes = 0;
        bool Walk(PdfDictionary node, int depth)
        {
            if (depth > MaxTreeDepth || ++nodes > MaxTreeNodes || !seen.Add(node)) return true;
            if (document.Array(node, "Names") is { } names)
            {
                for (int i = 0; i + 1 < names.Items.Count; i += 2)
                {
                    if (document.Resolve(names.Items[i]) is not PdfString key) continue;
                    if (!visit(names, new(Encoding.Latin1.GetString(key.Bytes), names.Items[i + 1]))) return false;
                }
            }
            if (document.Array(node, "Kids") is { } kids)
            {
                foreach (var kid in kids.Items)
                {
                    if (document.Resolve(kid) is PdfDictionary child && !Walk(child, depth + 1)) return false;
                }
            }
            return true;
        }
        Walk(root, 0);
    }
}
