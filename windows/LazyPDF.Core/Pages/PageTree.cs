namespace LazyPDF.Core;

// The page tree as the editing code leaves it: every change to the order or the set of pages ends
// in Set, which lays the tree out again. A node holds at most Fanout kids (ISO 32000-1 7.7.3.2
// puts no limit on it; other readers cope better with a shallow, even tree than with 5000 kids in one array).
internal static class PageTree
{
    private const int Fanout = 32;
    private const int MaxNodes = 1_000_000;
    private static readonly string[] Inheritable = ["Resources", "MediaBox", "CropBox", "Rotate"];

    private readonly record struct Leaf(PdfReference Ref, PdfDictionary Dict);

    private sealed class Layout
    {
        public List<(PdfReference Ref, PdfDictionary Dict)> Interior { get; } = [];
        public Dictionary<int, PdfDictionary> PageParent { get; } = [];
        public Dictionary<PdfDictionary, PdfDictionary> NodeParent { get; } = new(ReferenceEqualityComparer.Instance);
    }

    /// <summary>
    /// Makes <paramref name="order"/> the pages of the document, in that order. Values a page took
    /// from a node that is going away are written onto the page first. Inner nodes of the old tree
    /// are reused where the new one needs them, so that an edit near the end of a big file does not
    /// rewrite the whole tree.
    /// </summary>
    public static void Set(PdfDocument document, IReadOnlyList<PdfReference> order)
    {
        var (root, rootRef) = Root(document);
        var layout = Walk(document, root, rootRef.Number);
        var kept = order.Select(r => r.Number).ToHashSet();
        foreach (var page in document.Pages)
        {
            if (kept.Contains(page.Reference.Number)) Bake(document, page, root, layout);
        }

        var spare = new Queue<(PdfReference Ref, PdfDictionary Dict)>(layout.Interior);
        var leaves = order.Select(r => new Leaf(r, document.Resolve(r) as PdfDictionary ?? throw PdfReadException.Damaged("A page of the document is missing."))).ToArray();
        Fill(document, root, rootRef, leaves, spare);
        if (document.Name(root, "Type") != "Pages") root["Type"] = new PdfName("Pages");
        foreach (var (reference, _) in spare) document.Delete(reference.Number);
        document.RefreshPages();
    }

    private static (PdfDictionary Root, PdfReference Reference) Root(PdfDocument document)
    {
        var raw = document.Catalog["Pages"];
        if (raw is PdfReference reference && document.Resolve(reference) is PdfDictionary found) return (found, reference);
        var root = document.Resolve(raw) as PdfDictionary ?? new PdfDictionary();
        var added = document.Add(root);
        document.Catalog["Pages"] = added;
        return (root, added);
    }

    private static void Fill(PdfDocument document, PdfDictionary node, PdfReference nodeRef, ReadOnlySpan<Leaf> leaves,
        Queue<(PdfReference Ref, PdfDictionary Dict)> spare)
    {
        var kids = new List<PdfObject>();
        if (leaves.Length <= Fanout)
        {
            foreach (var leaf in leaves)
            {
                leaf.Dict["Parent"] = nodeRef;
                kids.Add(leaf.Ref);
            }
        }
        else
        {
            // The smallest power of the fan-out with which no more than Fanout children are needed.
            int each = Fanout;
            while ((long)each * Fanout < leaves.Length) each *= Fanout;
            for (int at = 0; at < leaves.Length; at += each)
            {
                var (childRef, child) = spare.TryDequeue(out var reused) ? reused : NewNode(document);
                Reset(child);
                child["Type"] = new PdfName("Pages");
                child["Parent"] = nodeRef;
                Fill(document, child, childRef, leaves.Slice(at, Math.Min(each, leaves.Length - at)), spare);
                kids.Add(childRef);
            }
        }
        node["Kids"] = new PdfArray(kids);
        node["Count"] = new PdfNumber(leaves.Length);
    }

    private static (PdfReference, PdfDictionary) NewNode(PdfDocument document)
    {
        var node = new PdfDictionary();
        return (document.Add(node), node);
    }

    private static void Reset(PdfDictionary node)
    {
        foreach (string key in node.Entries.Select(e => e.Key).Distinct().ToList()) node.Remove(key);
    }

    private static void Bake(PdfDocument document, PdfPage page, PdfDictionary root, Layout layout)
    {
        if (!layout.PageParent.TryGetValue(page.Reference.Number, out var parent)) return;
        foreach (string key in Inheritable)
        {
            if (page.Dictionary[key] is { } own and not PdfNull) continue;
            var node = parent;
            for (int depth = 0; node is not null && !ReferenceEquals(node, root) && depth < 256; depth++)
            {
                if (node[key] is { } value and not PdfNull)
                {
                    page.Dictionary[key] = value;
                    break;
                }
                node = layout.NodeParent.GetValueOrDefault(node);
            }
        }
    }

    /// <summary>The inner nodes below the root in the order a layout visits them, and which node holds each page, by following /Kids only, as the reader does.</summary>
    private static Layout Walk(PdfDocument document, PdfDictionary root, int rootNumber)
    {
        var layout = new Layout();
        var seen = new HashSet<int> { rootNumber };
        var stack = new Stack<(PdfReference? Ref, PdfDictionary Dict)>();
        stack.Push((null, root));
        while (stack.Count > 0 && seen.Count < MaxNodes)
        {
            var (self, node) = stack.Pop();
            if (self is not null) layout.Interior.Add((self, node));
            var inner = new List<(PdfReference, PdfDictionary)>();
            if (document.Array(node, "Kids") is { } kids)
            {
                foreach (var kid in kids.Items)
                {
                    if (kid is not PdfReference reference || !seen.Add(reference.Number)) continue;
                    if (document.Resolve(reference) is not PdfDictionary child) continue;
                    string? type = document.Name(child, "Type");
                    if (type != "Page" && (type == "Pages" || child.ContainsKey("Kids")))
                    {
                        layout.NodeParent[child] = node;
                        inner.Add((reference, child));
                    }
                    else
                    {
                        layout.PageParent[reference.Number] = node;
                    }
                }
            }
            for (int i = inner.Count - 1; i >= 0; i--) stack.Push(inner[i]);
        }
        return layout;
    }
}
