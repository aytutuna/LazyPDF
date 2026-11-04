namespace LazyPDF.Core;

// What has to change before pages are removed, so that nothing is left pointing at them. A
// reference left behind would also keep the removed page, and what it shows, in a rewritten file.
internal static class PageCleanup
{
    private const int MaxItems = 1_000_000;

    public static void BeforeDelete(PdfDocument document, IReadOnlyList<PdfPage> doomed)
    {
        var gone = doomed.Select(p => p.Reference.Number).ToHashSet();
        var names = new PageDestinations(document);
        bool Dead(PdfObject? destination) => names.PageOfAny(destination) is { } page && gone.Contains(page.Number);

        Outlines(document, Dead);
        foreach (var page in document.Pages)
        {
            if (gone.Contains(page.Reference.Number)) continue;
            DropLinks(document, page, Dead);
            Triggers(document, page.Dictionary, Dead);
        }
        OpenAction(document, Dead);
        names.RemoveWhere(Dead);
        foreach (var page in doomed) RemoveFields(document, page);
        Structure(document, doomed);
        Threads(document, gone);
        PageLabels.Removed(document, [.. doomed.Select(p => p.Index)], document.Pages.Count);
    }

    // The item stays, without a destination; a bookmark that goes nowhere is still a heading.
    private static void Outlines(PdfDocument document, Func<PdfObject?, bool> dead)
    {
        if (document.Dict(document.Catalog, "Outlines") is not { } root) return;
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var stack = new Stack<PdfDictionary>();
        stack.Push(root);
        while (stack.Count > 0 && seen.Count < MaxItems)
        {
            var item = stack.Pop();
            if (!seen.Add(item)) continue;
            Strip(document, item, dead);
            if (document.Dict(item, "Next") is { } next) stack.Push(next);
            if (document.Dict(item, "First") is { } first) stack.Push(first);
        }
    }

    private static void Strip(PdfDocument document, PdfDictionary holder, Func<PdfObject?, bool> dead)
    {
        if (holder.ContainsKey("Dest") && dead(holder["Dest"])) holder.Remove("Dest");
        Triggers(document, holder, dead);
    }

    private static void Triggers(PdfDocument document, PdfDictionary holder, Func<PdfObject?, bool> dead)
    {
        if (holder.ContainsKey("A"))
        {
            if (Action(document, holder["A"], dead, 0) is { } kept) holder["A"] = kept;
            else holder.Remove("A");
        }
        if (document.Dict(holder, "AA") is not { } additional) return;
        foreach (string key in additional.Entries.Select(e => e.Key).Distinct().ToList())
        {
            if (Action(document, additional[key], dead, 0) is { } kept) additional[key] = kept;
            else additional.Remove(key);
        }
    }

    // A GoTo to a gone page is dropped and the action that followed it takes its place.
    private static PdfObject? Action(PdfDocument document, PdfObject? value, Func<PdfObject?, bool> dead, int depth)
    {
        if (document.Resolve(value) is not PdfDictionary action) return value;
        PdfObject? next = action["Next"];
        if (depth < 32 && next is not null)
        {
            if (document.Resolve(next) is PdfArray list)
            {
                var kept = list.Items.Select(i => Action(document, i, dead, depth + 1)).OfType<PdfObject>().ToList();
                next = kept.Count == 0 ? null : new PdfArray(kept);
            }
            else next = Action(document, next, dead, depth + 1);
            if (next is null) action.Remove("Next");
            else action["Next"] = next;
        }
        bool gone = document.Name(action, "S") == "GoTo" && dead(action["D"]);
        return gone ? next : value;
    }

    private static void DropLinks(PdfDocument document, PdfPage page, Func<PdfObject?, bool> dead)
    {
        if (document.Array(page.Dictionary, "Annots") is not { } annots) return;
        foreach (var item in annots.Items)
        {
            if (document.Resolve(item) is PdfDictionary annotation) Strip(document, annotation, dead);
        }
    }

    private static void OpenAction(PdfDocument document, Func<PdfObject?, bool> dead)
    {
        var action = document.Resolve(document.Catalog["OpenAction"]);
        if (action is PdfArray)
        {
            if (dead(action)) document.Catalog.Remove("OpenAction");
        }
        else if (action is PdfDictionary)
        {
            if (Action(document, document.Catalog["OpenAction"], dead, 0) is { } kept) document.Catalog["OpenAction"] = kept;
            else document.Catalog.Remove("OpenAction");
        }
        if (document.Dict(document.Catalog, "AA") is not null) Triggers(document, document.Catalog, dead);
    }

    // A widget goes from its field; a field with no widget or sub-field left goes from its parent, up to /Fields.
    private static void RemoveFields(PdfDocument document, PdfPage page)
    {
        if (document.Dict(document.Catalog, "AcroForm") is not { } form || document.Array(page.Dictionary, "Annots") is not { } annots) return;
        var dropped = new List<PdfReference>();
        foreach (var item in annots.Items)
        {
            if (item is not PdfReference widget || document.Resolve(widget) is not PdfDictionary annotation || document.Name(annotation, "Subtype") != "Widget") continue;
            var node = widget;
            for (int depth = 0; depth < 32; depth++)
            {
                dropped.Add(node);
                if (document.Resolve(node) is PdfDictionary { } field && field["Parent"] is PdfReference up
                    && document.Resolve(up) is PdfDictionary parent && document.Array(parent, "Kids") is { } kids)
                {
                    var leaving = node;
                    int at = kids.Items.FindIndex(k => k is PdfReference r && r.Number == leaving.Number);
                    kids.Items.RemoveAll(k => k is PdfReference r && r.Number == leaving.Number);
                    if (at >= 0 && depth == 0) ForgetButton(document, parent, at, annotation);
                    if (kids.Items.Count > 0) break;
                    node = up;
                }
                else
                {
                    break;
                }
            }
        }
        if (document.Array(form, "Fields") is { } fields) fields.Items.RemoveAll(f => f is PdfReference r && dropped.Contains(r));
        if (document.Array(form, "CO") is { } order) order.Items.RemoveAll(f => f is PdfReference r && dropped.Contains(r));
    }

    /// <summary>
    /// A button of a radio group or check box set goes: its entry in /Opt, which is by position, goes with
    /// it, and the group's /V is Off when it named the state of this button.
    /// </summary>
    internal static void ForgetButton(PdfDocument document, PdfDictionary parent, int index, PdfDictionary widget)
    {
        if (document.Name(parent, "FT") is not (null or "Btn")) return;
        if (document.Array(parent, "Opt") is { } options && index < options.Items.Count) options.Items.RemoveAt(index);
        var states = document.Dict(document.Dict(widget, "AP"), "N");
        if (document.Name(parent, "V") is { } value && states is not null && value != "Off" && states.ContainsKey(value)) parent["V"] = new PdfName("Off");
    }

    private static void Structure(PdfDocument document, IReadOnlyList<PdfPage> doomed)
    {
        if (!document.Catalog.ContainsKey("StructTreeRoot")) return;
        bool Tagged(PdfPage page) => page.Dictionary.ContainsKey("StructParents")
            || document.Array(page.Dictionary, "Annots")?.Items.Any(a => document.Resolve(a) is PdfDictionary d && d.ContainsKey("StructParent")) == true;
        if (!doomed.Any(Tagged)) return;
        document.Catalog.Remove("StructTreeRoot");
        document.Catalog.Remove("MarkInfo");
        foreach (var page in document.Pages)
        {
            page.Dictionary.Remove("StructParents");
            if (document.Name(page.Dictionary, "Tabs") == "S") page.Dictionary.Remove("Tabs");
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            foreach (var item in annots.Items)
            {
                if (document.Resolve(item) is PdfDictionary annotation) annotation.Remove("StructParent");
            }
        }
    }

    // A bead on a page that goes leaves its article; an article with no bead left goes too.
    private static void Threads(PdfDocument document, HashSet<int> gone)
    {
        if (document.Array(document.Catalog, "Threads") is not { } threads) return;
        foreach (var item in threads.Items.ToList())
        {
            if (document.Resolve(item) is not PdfDictionary thread || thread["F"] is not PdfReference first) continue;
            var ring = new List<PdfReference>();
            var bead = first;
            while (ring.Count < MaxItems && !ring.Any(r => r.Number == bead.Number))
            {
                ring.Add(bead);
                if (document.Resolve(bead) is not PdfDictionary d || d["N"] is not PdfReference next) break;
                bead = next;
            }
            var kept = ring.Where(r => document.Resolve(r) is PdfDictionary d && !(d["P"] is PdfReference p && gone.Contains(p.Number))).ToList();
            if (kept.Count == ring.Count) continue;
            foreach (var removed in ring.Except(kept)) document.Delete(removed.Number);
            if (kept.Count == 0)
            {
                threads.Items.Remove(item);
                if (item is PdfReference reference) document.Delete(reference.Number);
                continue;
            }
            for (int i = 0; i < kept.Count; i++)
            {
                var d = (PdfDictionary)document.Resolve(kept[i])!;
                d["N"] = kept[(i + 1) % kept.Count];
                d["V"] = kept[(i + kept.Count - 1) % kept.Count];
            }
            thread["F"] = kept[0];
        }
    }
}
