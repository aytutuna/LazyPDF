namespace LazyPDF.Core;

// Layers that are off in the default view. Their content is cut out of the streams, found by the
// marked content (/OC BDC ... EMC) and the /OC of images and forms, and then the groups
// themselves are removed from the file.
internal sealed class SanitizeLayers(PdfDocument document)
{
    private LayerVisibility _visibility = null!;

    // Operation ranges to cut, by the page or form they belong to: (first operation, last operation or -1 for "the matching EMC").
    private readonly Dictionary<object, List<(int From, int To)>> _cuts = new(ReferenceEqualityComparer.Instance);

    private sealed class Finder(SanitizeLayers owner) : ContentVisitor
    {
        public override void BeginMarked(ContentContext context, MarkedContent marked)
        {
            if (marked.OptionalContent is { } group && owner._visibility.IsHidden(group)) owner.Cut(context.Forms.Count == 0 ? null : context.Forms[^1], context.OperatorIndex, -1);
        }

        public override void PaintImage(ContentContext context, ImageInfo image)
        {
            if (image.OptionalContent is { } group && owner._visibility.IsHidden(group)) owner.Cut(context.Forms.Count == 0 ? null : context.Forms[^1], context.OperatorIndex, context.OperatorIndex);
        }

        public override void BeginForm(ContentContext context, FormInfo form)
        {
            if (!form.IsPattern && form.OptionalContent is { } group && owner._visibility.IsHidden(group))
            {
                owner.Cut(context.Forms.Count < 2 ? null : context.Forms[^2], context.OperatorIndex, context.OperatorIndex);
            }
        }
    }

    private PdfPage? _page;

    private void Cut(PdfStream? form, int from, int to)
    {
        object key = form is null ? _page!.Dictionary : form;
        if (!_cuts.TryGetValue(key, out var list)) _cuts[key] = list = [];
        list.Add((from, to));
    }

    /// <summary>Returns the number of hidden layers; with <paramref name="remove"/> their content and the groups go.</summary>
    public int Run(bool remove)
    {
        var hiddenLayers = PdfLayers.Read(document).Layers.Where(l => !l.IsOn).ToList();
        if (hiddenLayers.Count == 0 || !remove) return hiddenLayers.Count;
        _visibility = new LayerVisibility(document);

        var finder = new Finder(this);
        var interpreter = new ContentInterpreter(document);
        foreach (var page in document.Pages)
        {
            _page = page;
            interpreter.Run(page, finder);
            foreach (var (form, matrix) in PageAppearances.Of(document, page)) interpreter.Run(form, finder, matrix);
        }
        foreach (var (owner, ranges) in _cuts)
        {
            if (owner is PdfDictionary pageDictionary) CutPage(document.Pages.First(p => ReferenceEquals(p.Dictionary, pageDictionary)), ranges);
            else CutForm((PdfStream)owner, ranges);
        }
        // The forms and pictures whose Do went are still named in the resources.
        if (_cuts.Count > 0) new OptimizeResources(document).Run();
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is not { } annots) continue;
            annots.Items.RemoveAll(item => document.Resolve(item) is PdfDictionary a && document.Dict(a, "OC") is { } group && _visibility.IsHidden(group));
        }
        var numbers = hiddenLayers.Select(l => l.Reference.Number).ToHashSet();
        PdfGraph.Detach(document, numbers);
        if (document.Dict(document.Catalog, "OCProperties") is { } properties && (document.Array(properties, "OCGs")?.Items.Count ?? 0) == 0)
        {
            document.Catalog.Remove("OCProperties");
        }
        return hiddenLayers.Count;
    }

    private void CutPage(PdfPage page, List<(int From, int To)> ranges)
    {
        byte[] data = page.Contents();
        var stream = new PdfStream(new PdfDictionary(), []);
        PdfGraph.SetData(stream, Remove(data, ranges));
        page.Dictionary["Contents"] = document.Add(stream);
    }

    private void CutForm(PdfStream form, List<(int From, int To)> ranges)
    {
        PdfGraph.SetData(form, Remove(document.Data(form), ranges));
    }

    private static byte[] Remove(byte[] data, List<(int From, int To)> ranges)
    {
        var operations = ContentParser.Parse(data);
        var cut = new List<(int Start, int End)>();
        foreach (var (from, to) in ranges)
        {
            if (from < 0 || from >= operations.Count) continue;
            int last = to;
            if (to < 0)
            {
                int depth = 0;
                last = operations.Count - 1;
                for (int i = from; i < operations.Count; i++)
                {
                    if (operations[i].Operator is "BMC" or "BDC") depth++;
                    else if (operations[i].Operator == "EMC" && --depth == 0)
                    {
                        last = i;
                        break;
                    }
                }
            }
            cut.Add((operations[from].Start, operations[last].End));
        }
        cut.Sort();
        var output = new MemoryStream();
        int position = 0;
        foreach (var (start, end) in cut)
        {
            if (end <= position) continue;
            if (start > position) output.Write(data, position, start - position);
            position = end;
        }
        output.Write(data, position, data.Length - position);
        return output.ToArray();
    }
}
