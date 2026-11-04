namespace LazyPDF.Core;

/// <summary>The tree being built while the pages are tagged one after the other: headings are levelled across pages, so state is carried from page to page.</summary>
internal sealed class TagSession
{
    private const int MaxHeadingLevel = 6;

    private readonly PdfDocument _document;
    private readonly StructureTree _tree;
    private readonly StructElement _root = new("Document");
    private readonly Dictionary<HeadingLook, int> _levels;
    private readonly List<(int Page, StructElement Element)> _figures = [];
    private int _level, _headings, _paragraphs, _lists, _tables, _artifacts;

    public TagSession(PdfDocument document, List<TagPage?> layouts)
    {
        _document = document;
        _tree = StructureTree.Create(document);
        _tree.Add(null, _root);

        // Biggest or boldest look is H1; looks past the sixth share the last level.
        var looks = new HashSet<HeadingLook>();
        foreach (var node in layouts.SelectMany(l => l?.Nodes ?? []).SelectMany(All))
        {
            if (node.Heading is { } look) looks.Add(look);
        }
        _levels = looks.OrderByDescending(l => l.Size).ThenByDescending(l => l.Bold)
            .Select((look, i) => (look, level: Math.Min(i + 1, MaxHeadingLevel))).ToDictionary(e => e.look, e => e.level);
    }

    public int Skipped { get; private set; }

    public static Dictionary<PdfStream, int> SharedStreams(PdfDocument document)
    {
        var uses = new Dictionary<PdfStream, int>(ReferenceEqualityComparer.Instance);
        foreach (var page in document.Pages)
        {
            foreach (var stream in Streams(document, page)) uses[stream] = uses.GetValueOrDefault(stream) + 1;
        }
        return uses;
    }

    public static List<PdfStream> Streams(PdfDocument document, PdfPage page)
    {
        var contents = document.Resolve(page.Dictionary["Contents"]);
        var items = contents is PdfArray array ? array.Items : [contents ?? PdfNull.Instance];
        return [.. items.Select(document.Resolve).OfType<PdfStream>()];
    }

    public void Write() => _tree.Write(_document);

    public AutoTagResult Result(int pages) => new(
        false, pages - Skipped, Skipped, _headings, _paragraphs, _lists, _tables, _figures.Count, _artifacts,
        [.. _figures.Select(f => new TaggedFigure(f.Page, f.Element.Reference!))]);

    private static IEnumerable<TagNode> All(TagNode node) => new[] { node }.Concat(node.Children.SelectMany(All));

    private static IEnumerable<TagNode> Leaves(TagNode node) =>
        node.Children.Count == 0 ? [node] : node.Children.SelectMany(Leaves);

    /// <summary>Rewrites the page's content and adds its elements. A page whose content cannot be read or does not parse the way the layout saw it is skipped untouched.</summary>
    public void Tag(PdfPage page, TagPage? layout)
    {
        if (layout is null || !TryTag(page, layout)) Skipped++;
    }

    private bool TryTag(PdfPage page, TagPage layout)
    {
        List<PdfStream>? streams = Streams(_document, page);
        var data = new List<byte[]>();
        var parsed = new List<IReadOnlyList<ContentOperation>>();
        try
        {
            foreach (var stream in streams)
            {
                data.Add(_document.Data(stream));
                parsed.Add(ContentParser.Parse(data[^1]));
            }
        }
        catch (PdfReadException)
        {
            return false;
        }

        // An operator may stand in a later stream than its operands (7.8.2); only then are the streams joined into one.
        var joined = ContentParser.Parse(page.Contents());
        if (!parsed.SelectMany(p => p).Select(o => (o.Operator, o.Operands.Count)).SequenceEqual(joined.Select(o => (o.Operator, o.Operands.Count))))
        {
            streams = null;
            data = [page.Contents()];
            parsed = [joined];
        }

        int level = _level;
        foreach (var node in layout.Nodes) CreateElements(node, page.Index, ref level);
        _level = level;

        // Text claims an operation before a figure does: a form that draws both is described by its words.
        var claims = new Dictionary<int, TagNode>();
        var leaves = layout.Nodes.SelectMany(Leaves).ToList();
        foreach (var leaf in leaves.OrderBy(l => l.Type == "Figure"))
        {
            foreach (int op in leaf.Operations) claims.TryAdd(op, leaf);
        }

        int mcid = 0;
        var properties = _document.Dict(page.Resources, "Properties");
        var planner = new ContentTagger(parsed, claims, name => _document.Dict(properties, name), node =>
        {
            _tree.Add(node.Element!, new StructContent(page.Index, mcid));
            return mcid++;
        });
        planner.Run();

        _artifacts += planner.Artifacts;
        if (streams is null)
        {
            var merged = new PdfStream(new PdfDictionary { ["Filter"] = new PdfName("FlateDecode") }, PdfFilterEncoders.Flate(ContentTagger.Apply(data[0], planner.Insertions[0])));
            page.Dictionary["Contents"] = _document.Add(merged);
        }
        else
        {
            for (int s = 0; s < streams.Count; s++)
            {
                if (planner.Insertions[s].Count == 0) continue;
                streams[s].Data = PdfFilterEncoders.Flate(ContentTagger.Apply(data[s], planner.Insertions[s]));
                streams[s].Dictionary["Filter"] = new PdfName("FlateDecode");
                streams[s].Dictionary.Remove("DecodeParms");
            }
        }
        page.Dictionary["Tabs"] = new PdfName("S");

        foreach (var node in layout.Nodes) Attach(_root, node, page.Index);
        AddAnnotations(page, layout);
        return true;
    }

    private void CreateElements(TagNode node, int page, ref int previousLevel)
    {
        if (node.Heading is { } look)
        {
            previousLevel = Math.Min(_levels[look], previousLevel + 1);
            node.Type = "H" + previousLevel;
        }
        node.Element = new StructElement(node.Type) { PageIndex = page };
        if (node.Type == "TH")
        {
            node.Element.Dictionary["A"] = new PdfDictionary { ["O"] = new PdfName("Table"), ["Scope"] = new PdfName("Column") };
        }
        foreach (var child in node.Children) CreateElements(child, page, ref previousLevel);
    }

    private static bool HasContent(TagNode node) =>
        node.Element!.Kids.Any(k => k is StructContent) || node.Children.Any(HasContent);

    private void Attach(StructElement parent, TagNode node, int page)
    {
        if (!HasContent(node)) return;
        _tree.Add(parent, node.Element!);
        foreach (var child in node.Children) Attach(node.Element!, child, page);
        switch (node.Type)
        {
            case "P": _paragraphs++; break;
            case "L": _lists++; break;
            case "Table": _tables++; break;
            case "Figure": _figures.Add((page, node.Element!)); break;
            default:
                if (node.Heading is not null) _headings++;
                break;
        }
    }

    private void AddAnnotations(PdfPage page, TagPage layout)
    {
        foreach (var annotation in layout.Annotations)
        {
            string type = annotation.Subtype switch { "Link" => "Link", "Widget" => "Form", _ => "Annot" };
            var element = new StructElement(type) { PageIndex = page.Index };
            _tree.Add(_root, element);
            _tree.Add(element, new StructObject(page.Index, annotation.Reference));

            if (_document.Resolve(annotation.Reference) is not PdfDictionary dictionary) continue;
            string contents = PdfText.Read(_document, dictionary, "Contents") ?? "";
            if (annotation.Subtype == "Link")
            {
                string alt = annotation.Text.Length > 0 ? annotation.Text : contents;
                if (alt.Length == 0 && _document.Dict(dictionary, "A") is { } action && _document.Resolve(action["URI"]) is PdfString uri) alt = PdfText.Decode(uri.Bytes);
                if (alt.Length > 0) element.Alt = alt;
                if (contents.Length == 0 && alt.Length > 0) dictionary["Contents"] = PdfText.ToObject(alt);
            }
            else if (contents.Length > 0)
            {
                element.Alt = contents;
            }
        }
    }
}
