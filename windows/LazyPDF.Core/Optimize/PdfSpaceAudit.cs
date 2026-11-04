namespace LazyPDF.Core;

// Gives every object of a file to the kind of content it serves. An object met from several
// places belongs to the first of the seeds below that reaches it.
internal sealed class PdfSpaceAudit(PdfDocument document)
{
    private static readonly HashSet<string> BackLinks = ["Parent", "P", "Pg"];

    private readonly Dictionary<int, SpaceKind> _assigned = [];
    private readonly Dictionary<SpaceKind, long> _bytes = Enum.GetValues<SpaceKind>().ToDictionary(k => k, _ => 0L);

    public SpaceAudit Run()
    {
        var catalog = document.Catalog;
        Walk(document.Trailer["Info"], SpaceKind.Metadata);
        Walk(catalog["Metadata"], SpaceKind.Metadata);
        var names = document.Dict(catalog, "Names");
        Walk(names?["EmbeddedFiles"], SpaceKind.Attachments);
        Walk(catalog["AF"], SpaceKind.Attachments);
        Walk(catalog["AcroForm"], SpaceKind.Forms);
        Walk(catalog["Pages"], SpaceKind.Content, "Annots");
        foreach (var page in document.Pages) Walk(page.Dictionary["Annots"], SpaceKind.Annotations);
        Walk(document.Trailer["Root"], SpaceKind.Structure);

        foreach (int number in document.ObjectNumbers)
        {
            if (_assigned.ContainsKey(number) || document.Get(number) is not { } value) continue;
            _bytes[SpaceKind.Unreferenced] += PdfGraph.SizeOf(document, value);
        }
        long accounted = _bytes.Values.Sum();
        _bytes[SpaceKind.Overhead] = Math.Max(0, document.Length - accounted);
        return new SpaceAudit(document.Length, _bytes);
    }

    private void Walk(PdfObject? start, SpaceKind kind, string? skip = null)
    {
        if (start is null) return;
        var stack = new Stack<(PdfObject Value, SpaceKind Kind, int Depth)>();
        stack.Push((start, kind, 0));
        while (stack.Count > 0)
        {
            var (value, current, depth) = stack.Pop();
            if (depth > 200) continue;
            if (value is PdfReference reference)
            {
                if (_assigned.ContainsKey(reference.Number) || document.Get(reference.Number) is not { } target) continue;
                current = Override(target, current);
                _assigned[reference.Number] = current;
                _bytes[current] += PdfGraph.SizeOf(document, target);
                stack.Push((target, current, depth + 1));
                continue;
            }
            if (value is PdfDictionary direct && depth > 0 && direct.ContainsKey("EF")) current = SpaceKind.Attachments;
            var inner = value is PdfStream s ? s.Dictionary : value;
            switch (inner)
            {
                case PdfDictionary dictionary:
                    foreach (var (key, item) in dictionary.Entries)
                    {
                        if (BackLinks.Contains(key) || key == skip) continue;
                        stack.Push((item, current, depth + 1));
                    }
                    break;
                case PdfArray array:
                    foreach (var item in array.Items) stack.Push((item, current, depth + 1));
                    break;
            }
        }
    }

    private SpaceKind Override(PdfObject target, SpaceKind kind)
    {
        var dictionary = target as PdfDictionary ?? (target as PdfStream)?.Dictionary;
        if (dictionary is null) return kind;
        if (target is PdfStream && document.Name(dictionary, "Subtype") == "Image") return SpaceKind.Images;
        if (document.Name(dictionary, "Type") is "Font" or "FontDescriptor") return SpaceKind.Fonts;
        if (dictionary.ContainsKey("EF")) return SpaceKind.Attachments;
        return kind;
    }
}
