namespace LazyPDF.Core;

// The layers of the copied pages are listed in the target's /OCProperties, hidden ones in /OFF, so
// that content the source kept off does not turn up visible (ISO 32000-1 8.11.4.3).
internal sealed partial class PageImporter
{
    private readonly HashSet<int> _layersAdded = [];

    private void MergeLayers()
    {
        if (_same || _source.Dict(_source.Catalog, "OCProperties") is not { } original) return;
        var listed = _source.Array(original, "OCGs")?.Items.OfType<PdfReference>().Select(r => r.Number).ToHashSet() ?? [];
        var config = _source.Dict(original, "D");
        bool baseOff = _source.Name(config, "BaseState") == "OFF";
        var on = Numbers(_source, config, "ON");
        var off = Numbers(_source, config, "OFF");

        foreach (var (number, made) in _map.ToList())
        {
            if (!listed.Contains(number) || !_layersAdded.Add(number)) continue;
            var properties = Ensure(_target.Catalog, "OCProperties");
            EnsureArray(properties, "OCGs").Items.Add(made);
            EnsureArray(Ensure(properties, "D"), "Order").Items.Add(made);
            if (baseOff ? !on.Contains(number) : off.Contains(number)) EnsureArray(Ensure(properties, "D"), "OFF").Items.Add(made);
        }
    }

    private static HashSet<int> Numbers(PdfDocument document, PdfDictionary? config, string key) =>
        document.Array(config, key)?.Items.OfType<PdfReference>().Select(r => r.Number).ToHashSet() ?? [];

    private PdfDictionary Ensure(PdfDictionary parent, string key)
    {
        if (_target.Dict(parent, key) is { } existing) return existing;
        var created = new PdfDictionary();
        parent[key] = created;
        return created;
    }

    private PdfArray EnsureArray(PdfDictionary parent, string key)
    {
        if (_target.Array(parent, key) is { } existing) return existing;
        var created = new PdfArray([]);
        parent[key] = created;
        return created;
    }
}
