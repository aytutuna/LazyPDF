namespace LazyPDF.Core;

/// <summary>The optional content group of a stamp run, tagged with the run's id so it can be found again (ISO 32000-1 8.11).</summary>
internal static class StampLayers
{
    public static PdfReference Add(PdfDocument document, int id, string name)
    {
        var print = new PdfDictionary();
        print["PrintState"] = new PdfName("ON");
        print["Subtype"] = new PdfName("Watermark");
        var view = new PdfDictionary();
        view["ViewState"] = new PdfName("ON");
        var usage = new PdfDictionary();
        usage["Print"] = print;
        usage["View"] = view;
        var group = new PdfDictionary();
        group["Type"] = new PdfName("OCG");
        group["Name"] = PdfText.ToObject(name);
        group["Usage"] = usage;
        group[StampStreams.Key] = new PdfNumber(id);
        var reference = document.Add(group);

        var properties = EnsureDict(document, document.Catalog, "OCProperties");
        EnsureArray(document, properties, "OCGs").Items.Add(reference);
        EnsureArray(document, EnsureDict(document, properties, "D"), "Order").Items.Add(reference);
        return reference;
    }

    public static void Remove(PdfDocument document, int id)
    {
        if (document.Dict(document.Catalog, "OCProperties") is not { } properties || document.Array(properties, "OCGs") is not { } groups) return;
        var mine = groups.Items.OfType<PdfReference>()
            .Where(r => document.Resolve(r) is PdfDictionary d && document.Integer(d, StampStreams.Key) == id).ToList();
        foreach (var reference in mine)
        {
            groups.Items.Remove(reference);
            Unlist(document, document.Dict(properties, "D"), reference);
            document.Delete(reference.Number);
        }
        if (mine.Count > 0 && groups.Items.Count == 0) document.Catalog.Remove("OCProperties");
    }

    // The configuration names a layer in more places than /Order.
    private static void Unlist(PdfDocument document, PdfDictionary? config, PdfReference layer)
    {
        if (config is null) return;
        var seen = new HashSet<PdfArray>(ReferenceEqualityComparer.Instance);
        foreach (string key in (ReadOnlySpan<string>)["Order", "ON", "OFF", "Locked", "RBGroups"])
        {
            if (document.Array(config, key) is { } array) Strip(document, array, layer, 0, seen);
        }
        if (document.Array(config, "AS") is { } states)
        {
            foreach (var state in states.Items)
            {
                if (document.Resolve(state) is PdfDictionary d && document.Array(d, "OCGs") is { } groups) Strip(document, groups, layer, 0, seen);
            }
        }
    }

    // An array that holds itself would otherwise be walked once per way into it.
    private static void Strip(PdfDocument document, PdfArray array, PdfReference layer, int depth, HashSet<PdfArray> seen)
    {
        if (!seen.Add(array)) return;
        array.Items.RemoveAll(i => i is PdfReference r && r.Number == layer.Number);
        if (depth > 8) return;
        foreach (var item in array.Items)
        {
            if (document.Resolve(item) is PdfArray inner) Strip(document, inner, layer, depth + 1, seen);
        }
    }

    private static PdfDictionary EnsureDict(PdfDocument document, PdfDictionary parent, string key)
    {
        if (document.Dict(parent, key) is { } existing) return existing;
        var created = new PdfDictionary();
        parent[key] = created;
        return created;
    }

    private static PdfArray EnsureArray(PdfDocument document, PdfDictionary parent, string key)
    {
        if (document.Array(parent, key) is { } existing) return existing;
        var created = new PdfArray([]);
        parent[key] = created;
        return created;
    }
}
