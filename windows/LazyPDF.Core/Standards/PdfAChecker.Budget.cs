namespace LazyPDF.Core;

// What checking may cost. A form is parsed once but run at every paint, so each paint is charged by the interpreter's own rules: its operations,
// the glyphs it shows, and the bytes inflated again when the interpreter has no room to keep it.
internal sealed partial class PdfAChecker
{
    private const long MaxStreamBytes = 64L << 20;

    // The interpreter's limits on a form: the most operations it runs, how deep forms nest, and how many it keeps parsed. It skips a longer or
    // deeper form without a trace, and inflates a form that did not fit in its cache again at every paint.
    private const int MaxFormOperations = 1_000_000;
    private const int MaxFormDepth = 20;
    private const int MaxCachedForms = 1024;
    private const long MaxCachedOperations = 4_000_000;

    // Inflating a byte is far cheaper than running an operation; the interpreter itself charges a form it did not keep at 1/64 of its size.
    private const int UncachedShift = 2;
    private const long DefaultWork = 1L << 30;
    private const long WorkPerFileByte = 16;

    private readonly record struct FormCost(int Operations, long Size, long Glyphs);

    private readonly Dictionary<PdfStream, FormCost> _formCosts = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _cachedForms = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _skippingForms = new(ReferenceEqualityComparer.Instance);
    private long _cachedOperations;

    // Bytes of content read and operations run, all pages, forms and appearances together; the interpreter limits one run only.
    private long _work;

    /// <summary>Overrides the work allowed; by default 1 GiB plus 16 units for each byte of the file, so a long file is not cut short for its length.</summary>
    internal long? MaxWork { get; init; }

    private bool OverBudget => _work > (MaxWork ?? DefaultWork + WorkPerFileByte * _doc.Length);

    private void Unreadable(string where) => Add("6.1.7", where, OverBudget ? PdfAText.TooMuchContent : PdfAText.ContentUnreadable);

    private void Charge(PdfStream form, string where)
    {
        if (!_formCosts.TryGetValue(form, out var known))
        {
            if (OverBudget) throw PdfReadException.Damaged(PdfAText.TooMuchContent);
            known = Measure(form, where);
        }
        if (known.Operations > MaxFormOperations) Add("6.1.7", where, PdfAText.TooMuchContent);
        _work += known.Operations + known.Glyphs + (IsKept(form, known.Operations) ? 0 : known.Size >> UncachedShift) + 1;
        if (OverBudget) throw PdfReadException.Damaged(PdfAText.TooMuchContent);
    }

    // A form that cannot be read costs what inflating it takes at most, and the interpreter keeps it as an empty list.
    private FormCost Measure(PdfStream form, string where)
    {
        FormCost cost;
        try
        {
            byte[] data = _doc.Data(form, MaxStreamBytes);
            var operations = CheckContent(data, where);
            cost = new FormCost(operations.Count, data.Length, ShownBytes(operations));
        }
        catch (PdfReadException)
        {
            Unreadable(where);
            cost = new FormCost(0, MaxStreamBytes, 0);
        }
        return _formCosts[form] = cost;
    }

    // Each byte of a shown string is at most one glyph the interpreter visits.
    private static long ShownBytes(IReadOnlyList<ContentOperation> operations)
    {
        long total = 0;
        foreach (var op in operations)
        {
            if (op.Operator is not ("Tj" or "TJ" or "'" or "\"") || op.Operands.Count == 0) continue;
            total += op.Operands[^1] switch
            {
                PdfString text => text.Bytes.Length,
                PdfArray array => array.Items.OfType<PdfString>().Sum(s => (long)s.Bytes.Length),
                _ => 0,
            };
        }
        return total;
    }

    // Follows the interpreter's cache, which takes forms in the order they are first painted and keeps a form it skipped or could not read as empty.
    private bool IsKept(PdfStream form, int operations)
    {
        if (_cachedForms.Contains(form)) return true;
        int held = operations > MaxFormOperations ? 0 : operations;
        if (_cachedForms.Count >= MaxCachedForms || _cachedOperations + held > MaxCachedOperations) return false;
        _cachedForms.Add(form);
        _cachedOperations += held;
        return true;
    }

    // At the depth limit the interpreter runs a form but not the forms and tiling patterns inside it, and says nothing. A pattern is entered when a path is
    // painted with it, whether the form set it or inherited it, unless it has been run already.
    private bool SkipsContent(PdfStream form, ContentContext context, Func<string, string, PdfObject?> find, ISet<PdfStream> walked)
    {
        if (_skippingForms.Contains(form)) return true;
        bool IsNewPattern(PdfObject? pattern) => pattern is PdfStream cell && _doc.Integer(cell.Dictionary, "PatternType") == 1 && !walked.Contains(cell);
        bool paints = false, patterned = IsNewPattern(context.State.FillColor.Pattern) || IsNewPattern(context.State.StrokeColor.Pattern);
        IReadOnlyList<ContentOperation> operations;
        try
        {
            byte[] data = _doc.Data(form, MaxStreamBytes);
            _work += data.Length;
            operations = ContentParser.Parse(data, MaxFormOperations);
        }
        catch (PdfReadException)
        {
            return false;
        }
        foreach (var op in operations)
        {
            switch (op.Operator)
            {
                case "Do" when op.Operands.Count > 0 && op.Operands[^1] is PdfName xobject && find("XObject", xobject.Value) is PdfStream entered
                    && (_doc.Name(entered.Dictionary, "Subtype") == "Form" || (!entered.Dictionary.ContainsKey("Subtype") && entered.Dictionary.ContainsKey("BBox"))):
                    _skippingForms.Add(form);
                    return true;
                case "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "S" or "s":
                    paints = true;
                    break;
                case "scn" or "SCN" when op.Operands.Count > 0 && op.Operands[^1] is PdfName pattern && IsNewPattern(find("Pattern", pattern.Value)):
                    patterned = true;
                    break;
            }
        }
        return paints && patterned;
    }
}
