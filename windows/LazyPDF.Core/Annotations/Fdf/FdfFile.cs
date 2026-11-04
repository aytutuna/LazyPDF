namespace LazyPDF.Core;

/// <summary>A field of an FDF or XFDF file (ISO 32000-1 12.7.7.3): its partial name, its value as written, and its kids.</summary>
public sealed record FdfField(string Name, PdfObject? Value, IReadOnlyList<FdfField> Kids);

/// <summary>An annotation of an FDF or XFDF file: the page it belongs to (from 0) and its dictionary.</summary>
public sealed record FdfAnnotation(int PageIndex, PdfDictionary Dictionary);

/// <summary>
/// What an FDF file holds (12.7.7), the same for XFDF (ISO 19444-1): the PDF it belongs to, field
/// values and annotations. Annotation dictionaries refer to each other (/IRT, /Popup) and to streams
/// through the file's own object table, as in an FDF file; one read from XFDF gets its objects when it
/// is first written or imported.
/// </summary>
public sealed class FdfFile
{
    private const int MaxObjects = 200_000;

    private int _next = 2;

    /// <summary>The /F entry: the file the data was exported from.</summary>
    public string? FileName { get; set; }

    public List<FdfField> Fields { get; } = [];

    public List<FdfAnnotation> Annotations { get; } = [];

    internal Dictionary<int, PdfObject> Objects { get; } = [];

    /// <summary>Follows a reference into the file's objects; anything else comes back as it is.</summary>
    public PdfObject? Resolve(PdfObject? value)
    {
        for (int hops = 0; hops < 32 && value is PdfReference reference; hops++) value = Objects.GetValueOrDefault(reference.Number);
        return value is PdfReference ? null : value;
    }

    /// <summary>The fields with their dotted full names, in order; fields with kids are listed only through their kids.</summary>
    public IReadOnlyList<KeyValuePair<string, PdfObject?>> FlatFields()
    {
        var list = new List<KeyValuePair<string, PdfObject?>>();
        foreach (var field in Fields) Flatten(field, "", list);
        return list;
    }

    private static void Flatten(FdfField field, string prefix, List<KeyValuePair<string, PdfObject?>> list)
    {
        if (list.Count >= MaxObjects) return;
        string name = prefix.Length == 0 ? field.Name : field.Name.Length == 0 ? prefix : prefix + "." + field.Name;
        if (field.Kids.Count == 0) list.Add(new(name, field.Value));
        else
        {
            if (field.Value is not null) list.Add(new(name, field.Value));
            foreach (var kid in field.Kids) Flatten(kid, name, list);
        }
    }

    internal PdfReference Reserve()
    {
        if (_next > MaxObjects) throw PdfReadException.Damaged("The FDF data holds too many objects.");
        var reference = new PdfReference(_next++, 0);
        Objects[reference.Number] = PdfNull.Instance;
        return reference;
    }

    internal void Store(PdfReference reference, PdfObject value) => Objects[reference.Number] = value;

    internal void Add(int number, PdfObject value)
    {
        Objects[number] = value;
        if (number >= _next) _next = number + 1;
    }

    /// <summary>
    /// Gives every annotation an object of its own, turns an /IRT that names an annotation by /NM (XFDF)
    /// into a reference, and a direct /Popup dictionary into a popup annotation. Safe to repeat.
    /// </summary>
    internal void Link()
    {
        var byDictionary = new Dictionary<PdfDictionary, PdfReference>();
        foreach (var (number, value) in Objects)
        {
            if (value is PdfDictionary dictionary) byDictionary[dictionary] = new PdfReference(number, 0);
        }
        foreach (var annotation in Annotations.ToList())
        {
            if (!byDictionary.ContainsKey(annotation.Dictionary))
            {
                var reference = Reserve();
                Store(reference, annotation.Dictionary);
                byDictionary[annotation.Dictionary] = reference;
            }
        }
        var byName = new Dictionary<string, PdfReference>();
        foreach (var annotation in Annotations)
        {
            if (annotation.Dictionary["NM"] is PdfString nm) byName.TryAdd(PdfText.Decode(nm.Bytes), byDictionary[annotation.Dictionary]);
        }
        foreach (var annotation in Annotations.ToList())
        {
            var d = annotation.Dictionary;
            if (d["IRT"] is PdfString by)
            {
                // A name that is none of this file's may be an annotation of the document it is imported into.
                if (byName.TryGetValue(PdfText.Decode(by.Bytes), out var parent)) d["IRT"] = parent;
            }
            if (d["Popup"] is PdfDictionary popup)
            {
                var reference = Reserve();
                popup["Subtype"] = new PdfName("Popup");
                popup["Parent"] = byDictionary[d];
                Store(reference, popup);
                byDictionary[popup] = reference;
                d["Popup"] = reference;
                Annotations.Add(new FdfAnnotation(annotation.PageIndex, popup));
            }
        }
    }
}
