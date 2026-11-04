namespace LazyPDF.Core;

/// <summary>
/// The tag tree after a redaction (ISO 32000-1 14.7): an element whose marked content or annotation
/// is gone leaves the tree, and an element that lost some of its content loses the /ActualText, /Alt
/// and /E that may repeat it. The parent and ID trees stop pointing at the elements that left.
/// </summary>
internal static class RedactionStructure
{
    private const int MaxDepth = 64;
    private const int MaxElements = 1_000_000;

    private static readonly string[] AltKeys = ["ActualText", "Alt", "E", "T"];

    /// <param name="tagged">Per page object number: how many items each marked content ID painted and how many of them were removed.</param>
    public static void Prune(PdfDocument document, Dictionary<int, Dictionary<int, (int Total, int Removed)>> tagged)
    {
        if (document.Dict(document.Catalog, "StructTreeRoot") is not { } root) return;
        var gone = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        int budget = MaxElements;
        Visit(document, root, null, tagged, gone, 0, ref budget);
        if (gone.Count == 0) return;

        bool Left(PdfObject? value) => document.Resolve(value) is PdfDictionary d && gone.Contains(d);
        if (document.Resolve(root["ParentTree"]) is PdfDictionary parents)
        {
            var kept = new List<KeyValuePair<long, PdfObject>>();
            foreach (var (key, value) in PdfNumberTree.Read(document, parents))
            {
                if (document.Resolve(value) is PdfArray list)
                {
                    foreach (int i in Enumerable.Range(0, list.Items.Count)) if (Left(list.Items[i])) list.Items[i] = PdfNull.Instance;
                    kept.Add(new(key, value));
                }
                else if (!Left(value)) kept.Add(new(key, value));
            }
            PdfNumberTree.Write(document, parents, kept);
        }
        if (document.Resolve(root["IDTree"]) is PdfDictionary ids)
        {
            var kept = PdfNameTree.Read(document, ids).Where(e => !Left(e.Value)).ToList();
            PdfNameTree.Write(document, ids, kept);
        }
    }

    /// <summary>Whether the element still has content; elements that have none are added to <paramref name="gone"/> by their parent.</summary>
    private static (bool Alive, bool Touched) Visit(PdfDocument document, PdfDictionary element, int? page,
        Dictionary<int, Dictionary<int, (int Total, int Removed)>> tagged, HashSet<PdfDictionary> gone, int depth, ref int budget)
    {
        if (depth > MaxDepth || --budget < 0) return (true, false);
        if (element["Pg"] is PdfReference own) page = own.Number;
        List<PdfObject> kids = document.Resolve(element["K"]) is PdfArray array ? [.. array.Items] : element["K"] is { } single ? [single] : [];
        var kept = new List<PdfObject>();
        bool touched = false;
        foreach (var kid in kids)
        {
            switch (document.Resolve(kid))
            {
                case PdfNumber n:
                    touched |= Content(page, (int)n.Value, tagged, kept, kid);
                    break;
                case PdfDictionary d when document.Name(d, "Type") == "MCR":
                    int? at = d["Pg"] is PdfReference mp ? mp.Number : page;
                    if (d.ContainsKey("Stm")) kept.Add(kid);
                    else touched |= Content(at, (int)(document.Integer(d, "MCID") ?? -1), tagged, kept, kid);
                    break;
                case PdfDictionary d when document.Name(d, "Type") == "OBJR":
                    if (document.Resolve(d["Obj"]) is null) touched = true;
                    else kept.Add(kid);
                    break;
                case PdfDictionary child:
                    var (alive, inner) = Visit(document, child, page, tagged, gone, depth + 1, ref budget);
                    touched |= inner;
                    if (alive) kept.Add(kid);
                    else
                    {
                        gone.Add(child);
                        touched = true;
                    }
                    break;
            }
        }
        if (kept.Count != kids.Count)
        {
            if (kept.Count == 0) element.Remove("K");
            else element["K"] = new PdfArray(kept);
        }
        if (touched) foreach (string key in AltKeys) element.Remove(key);
        // The root has no content of its own and stays.
        return (kept.Count > 0 || kids.Count == 0, touched);
    }

    // True when the content lost something; it stays in the tree unless every item it painted is gone.
    private static bool Content(int? page, int mcid, Dictionary<int, Dictionary<int, (int Total, int Removed)>> tagged,
        List<PdfObject> kept, PdfObject kid)
    {
        if (page is { } p && tagged.TryGetValue(p, out var counts) && counts.TryGetValue(mcid, out var c) && c.Removed > 0)
        {
            if (c.Removed < c.Total) kept.Add(kid);
            return true;
        }
        kept.Add(kid);
        return false;
    }
}
