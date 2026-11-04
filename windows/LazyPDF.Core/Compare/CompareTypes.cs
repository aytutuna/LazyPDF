namespace LazyPDF.Core;

public enum ChangeKind
{
    Added,
    Removed,
    Changed,

    /// <summary>A block of text, equal on both sides, found in another place.</summary>
    Moved,
}

public enum ChangeArea
{
    Text,

    /// <summary>Same words, another font, size or colour.</summary>
    Format,
    Image,
    Annotation,

    /// <summary>A page that was inserted, removed or moved, or changed size.</summary>
    Page,

    /// <summary>Metadata, bookmarks, attachments and form values.</summary>
    Document,
}

/// <summary>
/// One difference. Pages count from 0, -1 where a side has none. Quads are in user space of the page
/// on their own side. The side where text was removed or added holds a quad of zero width at that
/// spot. A picture or annotation that exists on one side only has no quad on the other, and a document
/// difference holds none.
/// </summary>
/// <param name="Detail">What differs, in words, for formats, images, annotations, pages and the document.</param>
public sealed record CompareChange(ChangeKind Kind, ChangeArea Area, int OldPage, int NewPage, string OldText, string NewText,
    IReadOnlyList<TextQuad> OldQuads, IReadOnlyList<TextQuad> NewQuads, string? Detail = null);

/// <summary>Two pages that are the same page in both files. An index is -1 for a page that has no partner.</summary>
/// <param name="Similarity">0 to 1, of the words (and of the pictures on a page with little text).</param>
/// <param name="Moved">The pair is out of order against the other pages.</param>
public sealed record PagePair(int OldIndex, int NewIndex, double Similarity, bool Moved)
{
    public bool IsAdded => OldIndex < 0;
    public bool IsRemoved => NewIndex < 0;
}

/// <param name="IgnoreCase">Letters that differ only in case are equal.</param>
/// <param name="IgnoreWhiteSpace">Words split or joined differently are equal ("data base" and "database").</param>
/// <param name="IgnoreHeaderFooter">Text in the top and bottom 7% of a page, as shown, is left out.</param>
public sealed record CompareOptions(bool IgnoreCase = false, bool IgnoreWhiteSpace = false, bool IgnoreHeaderFooter = false);

public sealed record ComparisonSummary(
    int Added, int Removed, int Changed, int Moved,
    int Text, int Format, int Images, int Annotations, int Pages, int Document,
    int WordsAdded, int WordsRemoved)
{
    public int Total => Added + Removed + Changed + Moved;
}

/// <param name="Pages">Every page of both files once, in the order of the new file with removed pages at their place.</param>
public sealed record ComparisonResult(IReadOnlyList<PagePair> Pages, IReadOnlyList<CompareChange> Changes, ComparisonSummary Summary,
    int OldPageCount, int NewPageCount)
{
    public bool IsIdentical => Changes.Count == 0;
}
