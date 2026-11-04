using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Name trees (ISO 32000-1 7.9.6): byte-string keys to values, in key order. A key is held as a
/// string with one character per byte, so it is the same under any text encoding and compares as
/// the file compares it; <see cref="KeyOf"/> and <see cref="TextOf"/> go to and from text.
/// </summary>
public static class PdfNameTree
{
    public static string KeyOf(string text) => Encoding.Latin1.GetString(PdfText.Encode(text));

    public static string TextOf(string key) => PdfText.Decode(Encoding.Latin1.GetBytes(key));

    /// <summary>The entries of the tree rooted at <paramref name="root"/>, in the order met; values as stored (not resolved). A loop, a branch past 32 levels or more than a million entries is cut off.</summary>
    public static IReadOnlyList<KeyValuePair<string, PdfObject>> Read(PdfDocument document, PdfObject? root)
    {
        var entries = new List<KeyValuePair<string, PdfObject>>();
        foreach (var (key, value) in PdfTrees.Leaves(document, root, "Names"))
        {
            if (document.Resolve(key) is PdfString s) entries.Add(new(Encoding.Latin1.GetString(s.Bytes), value));
        }
        return entries;
    }

    /// <summary>
    /// Rebuilds the tree from <paramref name="entries"/> (a repeated key: the last one counts) and
    /// returns its root, which is <paramref name="existing"/> changed in place when there is one.
    /// The old child nodes are freed.
    /// </summary>
    public static PdfDictionary Write(PdfDocument document, PdfDictionary? existing, IEnumerable<KeyValuePair<string, PdfObject>> entries)
    {
        var sorted = new SortedDictionary<string, PdfObject>(StringComparer.Ordinal);
        foreach (var (key, value) in entries) sorted[key] = value;
        return PdfTrees.Write(document, existing, "Names",
            [.. sorted.Select(e => (Key: (PdfObject)new PdfString(Encoding.Latin1.GetBytes(e.Key), false), e.Value))]);
    }
}

/// <summary>Number trees (ISO 32000-1 7.9.7): integer keys to values, in key order.</summary>
public static class PdfNumberTree
{
    public static IReadOnlyList<KeyValuePair<long, PdfObject>> Read(PdfDocument document, PdfObject? root)
    {
        var entries = new List<KeyValuePair<long, PdfObject>>();
        foreach (var (key, value) in PdfTrees.Leaves(document, root, "Nums"))
        {
            if (document.Resolve(key) is PdfNumber { Integer: { } n }) entries.Add(new(n, value));
        }
        return entries;
    }

    public static PdfDictionary Write(PdfDocument document, PdfDictionary? existing, IEnumerable<KeyValuePair<long, PdfObject>> entries)
    {
        var sorted = new SortedDictionary<long, PdfObject>();
        foreach (var (key, value) in entries) sorted[key] = value;
        return PdfTrees.Write(document, existing, "Nums", [.. sorted.Select(e => (Key: (PdfObject)new PdfNumber(e.Key), e.Value))]);
    }
}

internal static class PdfTrees
{
    private const int MaxDepth = 32;
    private const int MaxEntries = 1_000_000;
    private const int NodeSize = 64;

    public static List<(PdfObject Key, PdfObject Value)> Leaves(PdfDocument document, PdfObject? root, string leafKey)
    {
        var found = new List<(PdfObject, PdfObject)>();
        var visited = new HashSet<int>();
        Walk(root, 0);
        return found;

        void Walk(PdfObject? node, int depth)
        {
            if (depth > MaxDepth || found.Count >= MaxEntries) return;
            if (node is PdfReference reference && !visited.Add(reference.Number)) return;
            if (document.Resolve(node) is not PdfDictionary dictionary) return;
            if (document.Array(dictionary, leafKey) is { } leaves)
            {
                for (int i = 0; i + 1 < leaves.Items.Count && found.Count < MaxEntries; i += 2) found.Add((leaves.Items[i], leaves.Items[i + 1]));
            }
            if (document.Array(dictionary, "Kids") is { } kids)
            {
                foreach (var kid in kids.Items) Walk(kid, depth + 1);
            }
        }
    }

    public static PdfDictionary Write(PdfDocument document, PdfDictionary? existing, string leafKey, List<(PdfObject Key, PdfObject Value)> sorted)
    {
        var root = existing ?? new PdfDictionary();
        FreeKids(document, root);
        root.Remove("Names");
        root.Remove("Nums");
        root.Remove("Kids");
        root.Remove("Limits");
        if (sorted.Count <= NodeSize)
        {
            root[leafKey] = Pairs(sorted);
            return root;
        }

        var level = new List<(PdfObject First, PdfObject Last, PdfReference Node)>();
        for (int i = 0; i < sorted.Count; i += NodeSize)
        {
            var chunk = sorted.GetRange(i, Math.Min(NodeSize, sorted.Count - i));
            var leaf = new PdfDictionary { [leafKey] = Pairs(chunk), ["Limits"] = new PdfArray([chunk[0].Key, chunk[^1].Key]) };
            level.Add((chunk[0].Key, chunk[^1].Key, document.Add(leaf)));
        }
        while (level.Count > NodeSize)
        {
            var upper = new List<(PdfObject, PdfObject, PdfReference)>();
            for (int i = 0; i < level.Count; i += NodeSize)
            {
                var chunk = level.GetRange(i, Math.Min(NodeSize, level.Count - i));
                var node = new PdfDictionary
                {
                    ["Kids"] = new PdfArray([.. chunk.Select(c => (PdfObject)c.Node)]),
                    ["Limits"] = new PdfArray([chunk[0].First, chunk[^1].Last]),
                };
                upper.Add((chunk[0].First, chunk[^1].Last, document.Add(node)));
            }
            level = upper;
        }
        root["Kids"] = new PdfArray([.. level.Select(c => (PdfObject)c.Node)]);
        return root;
    }

    private static PdfArray Pairs(List<(PdfObject Key, PdfObject Value)> entries)
    {
        var items = new List<PdfObject>(entries.Count * 2);
        foreach (var (key, value) in entries)
        {
            items.Add(key);
            items.Add(value);
        }
        return new PdfArray(items);
    }

    private static void FreeKids(PdfDocument document, PdfDictionary node)
    {
        var visited = new HashSet<int>();
        int budget = 100_000;
        Free(node, 0);

        void Free(PdfDictionary current, int depth)
        {
            if (depth > MaxDepth || document.Array(current, "Kids") is not { } kids) return;
            foreach (var kid in kids.Items)
            {
                if (kid is not PdfReference reference || --budget < 0 || !visited.Add(reference.Number)) continue;
                if (document.Get(reference.Number) is PdfDictionary child) Free(child, depth + 1);
                document.Delete(reference.Number);
            }
        }
    }
}
