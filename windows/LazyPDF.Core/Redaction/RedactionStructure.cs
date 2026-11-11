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

    private static readonly string[] AltKeys = ["ActualText", "Alt", "E", "T", "AF"];

    /// <param name="tagged">Per page object number: how many items each marked content ID painted and how many of them were removed.</param>
    /// <param name="pictures">The object numbers of pages that became a picture: everything they showed is gone.</param>
    /// <param name="replaced">Pictures and forms that were copied or dropped, and what else was dropped; a content item or object that still names the original would keep it in the file.</param>
    /// <returns>False when the depth or element limit stopped the walk, so some of the tree was not checked.</returns>
    public static bool Prune(PdfDocument document, Dictionary<int, Dictionary<int, (int Total, int Removed)>> tagged, HashSet<PdfStream> replaced, HashSet<int> pictures)
    {
        if (document.Dict(document.Catalog, "StructTreeRoot") is not { } root) return true;
        var gone = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        int budget = MaxElements;
        bool limited = false;
        Visit(document, root, null, tagged, replaced, pictures, gone, 0, ref budget, ref limited);
        if (gone.Count == 0) return !limited;

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
        return !limited;
    }

    /// <summary>Whether the element still has content; elements that have none are added to <paramref name="gone"/> by their parent.</summary>
    private static (bool Alive, bool Touched) Visit(PdfDocument document, PdfDictionary element, int? page,
        Dictionary<int, Dictionary<int, (int Total, int Removed)>> tagged, HashSet<PdfStream> replaced, HashSet<int> pictures, HashSet<PdfDictionary> gone, int depth, ref int budget, ref bool limited)
    {
        if (depth > MaxDepth || --budget < 0)
        {
            Strip(document, element);
            limited = true;
            return (true, true);
        }
        if (element["Pg"] is PdfReference own) page = own.Number;
        List<PdfObject> kids = document.Resolve(element["K"]) is PdfArray array ? [.. array.Items] : element["K"] is { } single ? [single] : [];
        var kept = new List<PdfObject>();
        bool touched = false;
        foreach (var kid in kids)
        {
            switch (document.Resolve(kid))
            {
                // A kid that is not there, such as one a split left out, took its content with it.
                case null:
                    touched = true;
                    break;
                case PdfNumber n:
                    touched |= Content(page, (int)n.Value, tagged, pictures, kept, kid);
                    break;
                case PdfDictionary d when IsContentItem(document, d, "MCR", "MCID"):
                    int? at = d["Pg"] is PdfReference mp ? mp.Number : page;
                    if (d.ContainsKey("Stm"))
                    {
                        if ((document.Resolve(d["Stm"]) is PdfStream form && replaced.Contains(form)) || (at is { } stmPage && pictures.Contains(stmPage))) touched = true;
                        else kept.Add(kid);
                    }
                    else touched |= Content(at, (int)(document.Integer(d, "MCID") ?? -1), tagged, pictures, kept, kid);
                    break;
                case PdfDictionary d when IsContentItem(document, d, "OBJR", "Obj"):
                    int? holder = d["Pg"] is PdfReference op ? op.Number : page ?? (document.Resolve(d["Obj"]) is PdfDictionary owner && owner["P"] is PdfReference parent ? parent.Number : null);
                    if (document.Resolve(d["Obj"]) is null || (holder is { } shown && pictures.Contains(shown)) || (document.Resolve(d["Obj"]) is PdfStream target && replaced.Contains(target))) touched = true;
                    else kept.Add(kid);
                    break;
                case PdfDictionary child:
                    var (alive, inner) = Visit(document, child, page, tagged, replaced, pictures, gone, depth + 1, ref budget, ref limited);
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

    // Past the limits the tree is not followed, so no description below can be vouched for and none stays.
    private static void Strip(PdfDocument document, PdfDictionary element)
    {
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var open = new Stack<PdfDictionary>();
        open.Push(element);
        while (open.TryPop(out var current))
        {
            if (!seen.Add(current)) continue;
            foreach (string key in AltKeys) current.Remove(key);
            var kids = document.Resolve(current["K"]);
            foreach (var kid in kids is PdfArray array ? array.Items : kids is null ? [] : [kids])
            {
                if (document.Resolve(kid) is PdfDictionary child) open.Push(child);
            }
        }
    }

    // The type is required, but a writer that leaves it out still has a content item when there is no structure type.
    internal static bool IsContentItem(PdfDocument document, PdfDictionary item, string type, string key) =>
        document.Name(item, "Type") == type || (!item.ContainsKey("S") && !item.ContainsKey("Type") && item.ContainsKey(key));

    // True when the content lost something; it stays in the tree unless every item it painted is gone.
    private static bool Content(int? page, int mcid, Dictionary<int, Dictionary<int, (int Total, int Removed)>> tagged, HashSet<int> pictures,
        List<PdfObject> kept, PdfObject kid)
    {
        // With no page to match, the number is taken on every page.
        if (page is null)
        {
            kept.Add(kid);
            return pictures.Count > 0 || tagged.Values.Any(c => c.TryGetValue(mcid, out var m) && m.Removed > 0);
        }
        if (page is { } shown && pictures.Contains(shown)) return true;
        if (page is { } p && tagged.TryGetValue(p, out var counts) && counts.TryGetValue(mcid, out var c) && c.Removed > 0)
        {
            if (c.Removed < c.Total) kept.Add(kid);
            return true;
        }
        kept.Add(kid);
        return false;
    }
}
