namespace LazyPDF.Core;

/// <summary>A stretch of text in one style. <paramref name="Size"/> is in points.</summary>
public sealed record ExportRun(string Text, bool Bold, bool Italic, double Size);

/// <summary>A picture kept as it is (JPEG) or as PNG (everything else, an /SMask as alpha).</summary>
public sealed record ExportImage(byte[] Data, bool IsJpeg, int Width, int Height)
{
    public string Extension => IsJpeg ? "jpg" : "png";
    public string MimeType => IsJpeg ? "image/jpeg" : "image/png";
}

/// <summary>
/// A piece of the flow of a page. Bounds are display points: origin top left, y down, the page as
/// shown (crop box and /Rotate applied).
/// </summary>
public abstract record ExportBlock(DisplayRect Bounds);

/// <summary>A paragraph, a heading (<paramref name="Heading"/> 1 to 6) or an item of a list.</summary>
public sealed record ExportParagraph(DisplayRect Bounds, IReadOnlyList<ExportRun> Runs, int Heading = 0, ExportListItem? Item = null) : ExportBlock(Bounds)
{
    public string Text => string.Concat(Runs.Select(r => r.Text));
}

/// <summary>
/// An item of a list. Items with the same <paramref name="ListId"/> are one list; <paramref name="Level"/>
/// counts from 0, <paramref name="Number"/> is the number the item carries in an ordered list.
/// </summary>
public sealed record ExportListItem(int ListId, bool Ordered, int Level, int Number);

/// <summary>
/// A table; every row has <see cref="Columns"/> cells. <paramref name="Widths"/> are the column
/// widths in points when the page showed them (ruled tables), else null. <paramref name="Ruled"/>
/// says the page drew the grid.
/// </summary>
public sealed record ExportTable(DisplayRect Bounds, IReadOnlyList<IReadOnlyList<string>> Rows, IReadOnlyList<double>? Widths, bool Ruled) : ExportBlock(Bounds)
{
    public int Columns => Rows.Count == 0 ? 0 : Rows[0].Count;
}

public sealed record ExportPicture(DisplayRect Bounds, ExportImage Image) : ExportBlock(Bounds);

/// <summary>One line of the page where it sits, for the layouts that keep positions.</summary>
public sealed record ExportTextLine(DisplayRect Bounds, IReadOnlyList<ExportRun> Runs)
{
    public string Text => string.Concat(Runs.Select(r => r.Text));
}

/// <summary>
/// A page in display points. <paramref name="Blocks"/> is the reflowed content in reading order, page
/// headers and footers left out; <paramref name="Lines"/> are all the text lines of the page with
/// their places, <paramref name="Pictures"/> the pictures with theirs.
/// </summary>
public sealed record ExportPage(int Index, double Width, double Height, IReadOnlyList<ExportBlock> Blocks,
    IReadOnlyList<ExportTextLine> Lines, IReadOnlyList<ExportPicture> Pictures);

/// <summary>The model every writer works from.</summary>
/// <param name="BodySize">The size most text is set in, in points.</param>
/// <param name="PicturesLeftOut">How many pictures the memory limits kept out of the pages.</param>
public sealed record ExportDocument(string? Title, IReadOnlyList<ExportPage> Pages, double BodySize, int PicturesLeftOut = 0)
{
    public IEnumerable<ExportTable> Tables => Pages.SelectMany(p => p.Blocks.OfType<ExportTable>());
}
