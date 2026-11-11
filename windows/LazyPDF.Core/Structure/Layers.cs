namespace LazyPDF.Core;

/// <summary>An optional content group (ISO 32000-1 8.11.2) as the default configuration shows it.</summary>
public sealed record PdfLayer(PdfReference Reference, string Name, bool IsOn, bool Locked, string? Intent);

/// <summary>A row of the layers panel (/Order): a layer, a label over children, or both.</summary>
public sealed record LayerNode(string? Label, PdfLayer? Layer, IReadOnlyList<LayerNode> Children);

/// <summary>The layers of a document under its default configuration (/OCProperties /D).</summary>
public sealed record LayerSet(IReadOnlyList<PdfLayer> Layers, IReadOnlyList<LayerNode> Order, IReadOnlyList<IReadOnlyList<PdfReference>>? RadioGroups = null)
{
    public IReadOnlyList<IReadOnlyList<PdfReference>> RadioGroups { get; init; } = RadioGroups ?? [];
}

public static class PdfLayers
{
    private const int MaxLayers = 100_000;
    private const int MaxDepth = 16;

    /// <summary>
    /// The layers in /OCGs order and the tree of /Order (layers missing from it are appended at the
    /// top level). State follows /BaseState, /ON and /OFF; /AS usage rules are not applied. Empty
    /// when the file has no layers.
    /// </summary>
    public static LayerSet Read(PdfDocument document)
    {
        if (document.Dict(document.Catalog, "OCProperties") is not { } properties) return new LayerSet([], []);
        var config = document.Dict(properties, "D");
        string baseState = document.Name(config, "BaseState") ?? "ON";
        var on = Numbers(document, config, "ON");
        var off = Numbers(document, config, "OFF");
        var locked = Numbers(document, config, "Locked");

        var layers = new List<PdfLayer>();
        var byNumber = new Dictionary<int, PdfLayer>();
        foreach (var item in document.Array(properties, "OCGs")?.Items.Take(MaxLayers) ?? [])
        {
            if (item is not PdfReference reference || byNumber.ContainsKey(reference.Number)) continue;
            if (document.Resolve(item) is not PdfDictionary group) continue;
            bool state = baseState == "OFF" ? on.Contains(reference.Number) : !off.Contains(reference.Number);
            var layer = new PdfLayer(reference, PdfText.Read(document, group, "Name") ?? StructureText.UnnamedLayer, state,
                locked.Contains(reference.Number), Intent(document, group));
            layers.Add(layer);
            byNumber[reference.Number] = layer;
        }

        var placed = new HashSet<int>();
        var order = new List<LayerNode>();
        if (document.Array(config, "Order") is { } tree) order = Nodes(document, tree, byNumber, placed, [], 0);
        foreach (var layer in layers)
        {
            if (!placed.Contains(layer.Reference.Number)) order.Add(new LayerNode(null, layer, []));
        }
        return new LayerSet(layers, order, RadioGroups(document, config, byNumber));
    }

    /// <summary>
    /// Shows or hides a layer in the default configuration and writes /ON, /OFF and /BaseState
    /// anew: base state ON and the hidden layers listed in /OFF. Turning a layer on turns off the
    /// others of its radio button group (/RBGroups). Returns false for a layer the file does not list.
    /// </summary>
    public static bool SetVisible(PdfDocument document, PdfReference layer, bool visible)
    {
        var current = Read(document);
        if (current.Layers.All(l => l.Reference.Number != layer.Number)) return false;
        var off = current.Layers.Where(l => !l.IsOn).Select(l => l.Reference.Number).ToHashSet();
        if (visible)
        {
            off.Remove(layer.Number);
            foreach (var group in Groups(document, layer.Number)) off.UnionWith(group.Where(n => n != layer.Number));
        }
        else off.Add(layer.Number);

        var properties = document.Dict(document.Catalog, "OCProperties")!;
        var config = document.Dict(properties, "D");
        if (config is null)
        {
            config = new PdfDictionary();
            properties["D"] = config;
        }
        config.Remove("BaseState");
        config.Remove("ON");
        var hidden = current.Layers.Where(l => off.Contains(l.Reference.Number)).Select(l => (PdfObject)l.Reference).ToList();
        if (hidden.Count > 0) config["OFF"] = new PdfArray(hidden);
        else config.Remove("OFF");
        return true;
    }

    private static List<LayerNode> Nodes(PdfDocument document, PdfArray array, Dictionary<int, PdfLayer> layers, HashSet<int> placed, HashSet<PdfArray> visited, int depth)
    {
        var nodes = new List<LayerNode>();
        // An array that lists itself, or that several arrays list, is read once: the tree is the file's, not a count of the ways to walk it.
        if (depth > MaxDepth || !visited.Add(array)) return nodes;
        bool afterRow = false;
        foreach (var item in array.Items.Take(MaxLayers))
        {
            var resolved = document.Resolve(item);
            if (resolved is PdfArray children)
            {
                // An array right after a layer or a label is that row's children; otherwise it is a group without a name.
                var inner = Nodes(document, children, layers, placed, visited, depth + 1);
                if (afterRow) nodes[^1] = nodes[^1] with { Children = inner };
                else nodes.Add(new LayerNode(null, null, inner));
                afterRow = false;
            }
            else if (resolved is PdfString label)
            {
                nodes.Add(new LayerNode(PdfText.Decode(label.Bytes), null, []));
                afterRow = true;
            }
            else if (item is PdfReference r && layers.TryGetValue(r.Number, out var layer) && placed.Add(r.Number))
            {
                nodes.Add(new LayerNode(null, layer, []));
                afterRow = true;
            }
            else afterRow = false;
        }
        return nodes;
    }

    private static List<IReadOnlyList<PdfReference>> RadioGroups(PdfDocument document, PdfDictionary? config, Dictionary<int, PdfLayer> layers)
    {
        var result = new List<IReadOnlyList<PdfReference>>();
        foreach (var group in document.Array(config, "RBGroups")?.Items.Take(MaxLayers) ?? [])
        {
            if (document.Resolve(group) is not PdfArray members) continue;
            var known = members.Items.OfType<PdfReference>().Where(r => layers.ContainsKey(r.Number)).ToList();
            if (known.Count >= 2) result.Add(known);
        }
        return result;
    }

    private static HashSet<int> Numbers(PdfDocument document, PdfDictionary? config, string key) =>
        [.. document.Array(config, key)?.Items.Take(MaxLayers).OfType<PdfReference>().Select(r => r.Number) ?? []];

    private static string? Intent(PdfDocument document, PdfDictionary group) => document.Resolve(group["Intent"]) switch
    {
        PdfName n => n.Value,
        PdfArray a when a.Items.Count > 0 && document.Resolve(a.Items[0]) is PdfName first => first.Value,
        _ => null,
    };

    private static IEnumerable<HashSet<int>> Groups(PdfDocument document, int number)
    {
        var config = document.Dict(document.Dict(document.Catalog, "OCProperties"), "D");
        foreach (var group in document.Array(config, "RBGroups")?.Items.Take(MaxLayers) ?? [])
        {
            if (document.Resolve(group) is not PdfArray members) continue;
            var numbers = members.Items.OfType<PdfReference>().Select(r => r.Number).ToHashSet();
            if (numbers.Contains(number)) yield return numbers;
        }
    }
}

/// <summary>Which optional content is off in the default view: the groups that are, and the membership dictionaries (8.11.2.2) that follow from them.</summary>
internal sealed class LayerVisibility
{
    private readonly PdfDocument _document;
    private readonly HashSet<PdfDictionary> _off = new(ReferenceEqualityComparer.Instance);

    public LayerVisibility(PdfDocument document)
    {
        _document = document;
        foreach (var layer in PdfLayers.Read(document).Layers.Where(l => !l.IsOn))
        {
            if (document.Get(layer.Reference.Number) is PdfDictionary group) _off.Add(group);
        }
    }

    public bool AnyOff => _off.Count > 0;

    // /VE expressions are not evaluated and count as visible.
    public bool IsHidden(PdfDictionary group)
    {
        if (_off.Contains(group)) return true;
        if (_document.Name(group, "Type") != "OCMD" || group.ContainsKey("VE")) return false;
        var members = _document.Resolve(group["OCGs"]) switch
        {
            PdfDictionary single => [single],
            PdfArray array => array.Items.Select(i => _document.Resolve(i) as PdfDictionary).OfType<PdfDictionary>().ToList(),
            _ => new List<PdfDictionary>(),
        };
        if (members.Count == 0) return false;
        int off = members.Count(_off.Contains);
        return (_document.Name(group, "P") ?? "AnyOn") switch
        {
            "AllOn" => off > 0,
            "AnyOff" => off == 0,
            "AllOff" => off < members.Count,
            _ => off == members.Count,
        };
    }
}
