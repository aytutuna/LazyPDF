namespace LazyPDF.Core;

// Drops the resources a page or form lists but its content never names. A resource dictionary
// shared by several owners keeps what any of them uses; one whose content cannot be read is
// left whole.
internal sealed class OptimizeResources(PdfDocument document)
{
    private static readonly string[] Categories = ["Font", "XObject", "ExtGState", "ColorSpace", "Pattern", "Shading", "Properties"];
    private const int MaxDepth = 8;

    private sealed class Usage
    {
        public readonly Dictionary<string, HashSet<string>> Names = Categories.ToDictionary(c => c, _ => new HashSet<string>());
        public bool Unsafe;
    }

    private readonly Dictionary<PdfDictionary, Usage> _usage = new(ReferenceEqualityComparer.Instance);

    public int Run()
    {
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (document.Name(dictionary, "Subtype") != "Type3") continue;
            if (document.Dict(dictionary, "Resources") is not { } own) return 0;
            UsageOf(own).Unsafe = true;
        }
        foreach (var page in document.Pages)
        {
            if (page.Resources is not { } resources) continue;
            var usage = UsageOf(resources);
            var contents = document.Resolve(page.Dictionary["Contents"]);
            foreach (var item in contents is PdfArray list ? list.Items : [contents ?? PdfNull.Instance])
            {
                if (document.Resolve(item) is PdfStream part) CollectStream(part, resources, usage);
            }
            foreach (var stream in AppearancesWithoutResources(page)) CollectStream(stream, resources, usage);
        }
        foreach (var (_, value) in PdfGraph.Objects(document))
        {
            if (value is not PdfStream stream || document.Dict(stream.Dictionary, "Resources") is not { } resources) continue;
            if (document.Name(stream.Dictionary, "Subtype") != "Form" && document.Integer(stream.Dictionary, "PatternType") != 1) continue;
            CollectStream(stream, resources, UsageOf(resources));
        }
        int removed = 0;
        foreach (var (resources, usage) in _usage)
        {
            if (usage.Unsafe) continue;
            foreach (string category in Categories)
            {
                if (document.Dict(resources, category) is not { } entries) continue;
                foreach (var (name, _) in entries.Entries.ToArray())
                {
                    if (usage.Names[category].Contains(name) || category == "ColorSpace" && name.StartsWith("Default", StringComparison.Ordinal)) continue;
                    entries.Remove(name);
                    removed++;
                }
            }
        }
        return removed;
    }

    private Usage UsageOf(PdfDictionary resources)
    {
        if (!_usage.TryGetValue(resources, out var usage)) _usage[resources] = usage = new Usage();
        return usage;
    }

    private void CollectStream(PdfStream stream, PdfDictionary resources, Usage usage)
    {
        try
        {
            Collect(document.Data(stream), resources, usage, 0, []);
        }
        catch (PdfReadException)
        {
            usage.Unsafe = true;
        }
    }

    // Appearance streams written without /Resources borrow the page's.
    private IEnumerable<PdfStream> AppearancesWithoutResources(PdfPage page)
    {
        foreach (var item in document.Array(page.Dictionary, "Annots")?.Items ?? [])
        {
            if (document.Dict(document.Resolve(item) as PdfDictionary, "AP") is not { } ap) continue;
            foreach (var (_, state) in ap.Entries)
            {
                var resolved = document.Resolve(state);
                IEnumerable<PdfObject?> streams = resolved is PdfDictionary states ? states.Entries.Select(e => document.Resolve(e.Value)) : [resolved];
                foreach (var candidate in streams)
                {
                    if (candidate is PdfStream s && document.Dict(s.Dictionary, "Resources") is null) yield return s;
                }
            }
        }
    }

    private void Collect(byte[] content, PdfDictionary resources, Usage usage, int depth, HashSet<PdfStream> seen)
    {
        foreach (var op in ContentParser.Parse(content))
        {
            switch (op.Operator)
            {
                case "Do" when Name(op, 0) is { } xobject:
                    usage.Names["XObject"].Add(xobject);
                    // A form with no resources of its own runs in its caller's.
                    if (document.Dict(resources, "XObject") is { } xobjects && document.Resolve(xobjects[xobject]) is PdfStream form
                        && document.Name(form.Dictionary, "Subtype") == "Form" && document.Dict(form.Dictionary, "Resources") is null && seen.Add(form))
                    {
                        if (depth >= MaxDepth)
                        {
                            usage.Unsafe = true;
                            break;
                        }
                        try
                        {
                            Collect(document.Data(form), resources, usage, depth + 1, seen);
                        }
                        catch (PdfReadException)
                        {
                            usage.Unsafe = true;
                        }
                    }
                    break;
                case "Tf" when Name(op, 0) is { } font:
                    usage.Names["Font"].Add(font);
                    break;
                case "gs" when Name(op, 0) is { } state:
                    usage.Names["ExtGState"].Add(state);
                    break;
                case "cs" or "CS" when Name(op, 0) is { } space:
                    usage.Names["ColorSpace"].Add(space);
                    break;
                case "sc" or "scn" or "SC" or "SCN" when op.Operands.Count > 0 && op.Operands[^1] is PdfName pattern:
                    usage.Names["Pattern"].Add(pattern.Value);
                    break;
                case "sh" when Name(op, 0) is { } shading:
                    usage.Names["Shading"].Add(shading);
                    break;
                case "BDC" or "DP" when op.Operands.Count >= 2 && op.Operands[^1] is PdfName property:
                    usage.Names["Properties"].Add(property.Value);
                    break;
                case "BI" when op.Image is { } image && (image.Dictionary["CS"] ?? image.Dictionary["ColorSpace"]) is PdfName inlineSpace:
                    usage.Names["ColorSpace"].Add(inlineSpace.Value);
                    break;
            }
        }
    }

    private static string? Name(ContentOperation op, int index) => op.Operands.Count > index && op.Operands[index] is PdfName n ? n.Value : null;
}
