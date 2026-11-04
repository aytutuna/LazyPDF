namespace LazyPDF.Core;

/// <summary>Anything that can sit in an element's /K: a child element, a marked-content sequence or an object reference.</summary>
public abstract class StructKid
{
    internal StructKid()
    {
    }

    /// <summary>The element that holds this one; null for a root element and for a kid that is not in a tree yet.</summary>
    public StructElement? Parent { get; internal set; }
}

/// <summary>A marked-content sequence of a page (ISO 32000-1 14.7.4.2), found by its /MCID in the content.</summary>
public sealed class StructContent(int pageIndex, int mcid, PdfReference? stream = null) : StructKid
{
    public int PageIndex { get; } = pageIndex;
    public int Mcid { get; } = mcid;

    /// <summary>The form XObject whose content holds the sequence; null when it is in the page's own content.</summary>
    public PdfReference? Stream { get; } = stream;
}

/// <summary>An object reference (OBJR): an annotation or XObject that belongs to an element.</summary>
public sealed class StructObject(int pageIndex, PdfReference target) : StructKid
{
    public int PageIndex { get; } = pageIndex;
    public PdfReference Target { get; } = target;
}

/// <summary>
/// One structure element (14.7.2). Properties read from the file and the live <see cref="Dictionary"/>
/// are kept: keys this class has no property for (attributes, class names, revisions) stay as they were.
/// </summary>
public sealed class StructElement : StructKid
{
    internal List<StructKid> KidList { get; } = [];

    public StructElement(string type) : this(type, new PdfDictionary(), null)
    {
    }

    internal StructElement(string type, PdfDictionary dictionary, PdfReference? reference)
    {
        Type = type;
        Dictionary = dictionary;
        Reference = reference;
    }

    /// <summary>The structure type as written (/S), which a role map may take to a standard one.</summary>
    public string Type { get; set; }

    public string? Title { get; set; }
    public string? Alt { get; set; }
    public string? Lang { get; set; }
    public string? ActualText { get; set; }
    public string? Id { get; set; }

    /// <summary>The page the element's content is on (/Pg), -1 when none is named. Written from the first content kid when left at -1.</summary>
    public int PageIndex { get; set; } = -1;

    /// <summary>Null until the element is written or when the file held it as a direct dictionary.</summary>
    public PdfReference? Reference { get; internal set; }

    public PdfDictionary Dictionary { get; }

    public IReadOnlyList<StructKid> Kids => KidList;

    public IEnumerable<StructElement> Children => KidList.OfType<StructElement>();

    public override string ToString() => $"{Type} ({KidList.Count} kids)";
}
