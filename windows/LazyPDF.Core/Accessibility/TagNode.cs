namespace LazyPDF.Core;

/// <summary>A heading's look: the size in points to half a point and whether it is bold. Headings with the same look get the same level.</summary>
internal readonly record struct HeadingLook(double Size, bool Bold);

/// <summary>
/// An element the layout analysis decided on, before any of the file is changed: its type, what is
/// under it and the page-level operations whose output belongs to it.
/// </summary>
internal sealed class TagNode(string type)
{
    public string Type { get; set; } = type;

    public List<TagNode> Children { get; } = [];

    /// <summary>Operations of the page's own content that draw this node's text or picture, in drawing order.</summary>
    public List<int> Operations { get; } = [];

    public HeadingLook? Heading { get; set; }

    /// <summary>Where the node sits on the page as shown, from the top left.</summary>
    public DisplayRect Area { get; set; }

    public StructElement? Element { get; set; }
}

/// <summary>An annotation of a page that gets its own element.</summary>
internal sealed record TagAnnotation(PdfReference Reference, string Subtype, string Text);

internal sealed class TagPage(int index)
{
    public int Index { get; } = index;

    public List<TagNode> Nodes { get; } = [];

    public List<TagAnnotation> Annotations { get; } = [];
}
