namespace LazyPDF.Core;

/// <summary>An image drawn by a page, with the page-level operation that draws it (the <c>Do</c> of the outermost form it sits in).</summary>
internal sealed record ScannedImage(int Operation, PdfRect Bounds);

/// <summary>
/// What the tagger needs from a run of the interpreter that the text layout does not give: the
/// images, and for a form its <c>Do</c> in the page's own content, since a marked-content sequence
/// can only be opened around that.
/// </summary>
internal sealed class TagScan : ContentVisitor
{
    private int _top = -1;

    public bool Truncated { get; private set; }

    public List<ScannedImage> Images { get; } = [];

    public Dictionary<PdfStream, int> FormOperations { get; } = new(ReferenceEqualityComparer.Instance);

    /// <summary>Forms drawn from more than one place; their content cannot be told apart per drawing.</summary>
    public HashSet<PdfStream> Repeated { get; } = new(ReferenceEqualityComparer.Instance);

    public static TagScan Run(ContentInterpreter interpreter, PdfPage page)
    {
        var scan = new TagScan();
        bool patterns = interpreter.WalkPatterns;
        interpreter.WalkPatterns = false;
        try
        {
            interpreter.Run(page, scan);
            scan.Truncated = interpreter.IsTruncated;
        }
        catch (PdfReadException)
        {
            scan.Truncated = true;
        }
        finally
        {
            interpreter.WalkPatterns = patterns;
        }
        return scan;
    }

    public override void BeginForm(ContentContext context, FormInfo form)
    {
        if (context.Forms.Count == 1) _top = context.OperatorIndex;
        if (!FormOperations.TryAdd(form.Stream, _top) && FormOperations[form.Stream] != _top) Repeated.Add(form.Stream);
    }

    public override void PaintImage(ContentContext context, ImageInfo image) =>
        Images.Add(new ScannedImage(context.Forms.Count == 0 ? context.OperatorIndex : _top, image.Bounds));
}
