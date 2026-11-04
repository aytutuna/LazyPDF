namespace LazyPDF.Core;

// A walk of every page and its current appearances that remembers which resource dictionaries it
// reached. What a dictionary lists but the walk never reached may be used by content nobody ran
// (soft mask groups, other appearance states, Type 3 glyph procedures, forms past the interpreter's
// limits), so callers must treat it as unseen. A dictionary shared with content that did not run
// counts as unseen too. Complete is false when no such reading can be trusted.
internal abstract class OptimizeWalk : ContentVisitor
{
    // The interpreter runs nothing of a form past these.
    private const long MaxFormSize = 64L << 20;
    private const int MaxFormOperations = 1_000_000;
    // What PdfPage.Contents stops reading at.
    private const long MaxContentSize = 256L << 20;

    private readonly HashSet<PdfDictionary> _reached = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfDictionary> _unrun = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _forms = new(ReferenceEqualityComparer.Instance);
    private PdfDocument _document = null!;

    /// <summary>Every use was walked: no run was cut short, no stream was unreadable, and no content that needs its caller's resources went unrun.</summary>
    public bool Complete { get; private set; } = true;

    /// <summary>User space units per point on the page being walked (14.11.2.3).</summary>
    protected double UserUnit { get; private set; } = 1;

    public bool Reached(PdfDictionary resources) => _reached.Contains(resources) && !_unrun.Contains(resources);

    public void Walk(PdfDocument document)
    {
        _document = document;
        var interpreter = new ContentInterpreter(document);
        foreach (var page in document.Pages)
        {
            UserUnit = page.UserUnit;
            if (page.Resources is { } resources) _reached.Add(resources);
            if (!Readable(page)) Complete = false;
            interpreter.Run(page, this);
            if (interpreter.IsTruncated) Complete = false;
            foreach (var (form, matrix) in PageAppearances.Of(document, page))
            {
                RunAppearance(interpreter, page, form, matrix);
                if (interpreter.IsTruncated) Complete = false;
            }
        }
        foreach (var (_, value) in PdfGraph.Objects(document))
        {
            if (value is PdfStream stream && !_forms.Contains(stream)
                && (document.Name(stream.Dictionary, "Subtype") == "Form" || document.Integer(stream.Dictionary, "PatternType") == 1))
            {
                if (document.Dict(stream.Dictionary, "Resources") is { } own) _unrun.Add(own);
                else if (UsesResources(stream)) Complete = false;
            }
        }
        // Glyph procedures are never run, so their resources and their caller's are both unseen.
        foreach (var dictionary in PdfGraph.AllDictionaries(document))
        {
            if (document.Name(dictionary, "Subtype") != "Type3") continue;
            if (document.Dict(dictionary, "Resources") is { } own) _unrun.Add(own);
            else Complete = false;
        }
    }

    public override void BeginForm(ContentContext context, FormInfo form)
    {
        if (!_forms.Add(form.Stream)) return;
        if (_document.Dict(form.Stream.Dictionary, "Resources") is { } resources) _reached.Add(resources);
        try
        {
            ContentParser.Parse(_document.Data(form.Stream, MaxFormSize), MaxFormOperations);
        }
        catch (PdfReadException)
        {
            Complete = false;
        }
    }

    // An appearance without /Resources runs in the page's (7.8.3), which the interpreter does not know for a form run on its own.
    private void RunAppearance(ContentInterpreter interpreter, PdfPage page, PdfStream form, PdfMatrix matrix)
    {
        if (form.Dictionary.ContainsKey("Resources") || page.Resources is not { } borrowed)
        {
            interpreter.Run(form, this, matrix);
            return;
        }
        form.Dictionary["Resources"] = borrowed;
        try
        {
            interpreter.Run(form, this, matrix);
        }
        finally
        {
            form.Dictionary.Remove("Resources");
        }
    }

    private bool Readable(PdfPage page)
    {
        long room = MaxContentSize;
        var contents = _document.Resolve(page.Dictionary["Contents"]);
        foreach (var item in contents is PdfArray list ? list.Items : [contents ?? PdfNull.Instance])
        {
            if (_document.Resolve(item) is not PdfStream stream) continue;
            try
            {
                room = Math.Max(0, room - _document.Data(stream, room).Length - 1);
            }
            catch (PdfReadException)
            {
                return false;
            }
        }
        return true;
    }

    // Whether content that never ran names a font, XObject or graphics state, which it would look up in its caller's resources.
    private bool UsesResources(PdfStream stream)
    {
        try
        {
            return ContentParser.Parse(_document.Data(stream, MaxFormSize), MaxFormOperations).Any(op => op.Operator is "Tf" or "Do" or "gs");
        }
        catch (PdfReadException)
        {
            return true;
        }
    }
}
