namespace LazyPDF.Core;

// Text in content the interpreter does not run: the soft mask groups of graphics states, the glyph procedures of Type 3 fonts and the cells of
// tiling patterns that text or an image mask is painted with. Nothing is decoded there, so a font that shows text is held to the font rules
// with no codes noted for it. A group or glyph is scanned as painted only once something paints with it; before that its fonts count but its
// device colour spaces do not.
internal sealed partial class PdfAChecker
{
    private const int MaxSavedStates = 256;

    private readonly HashSet<PdfStream> _textScanned = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfStream> _textPainted = new(ReferenceEqualityComparer.Instance);
    private readonly Dictionary<PdfDictionary, bool> _proceduresScanned = new(ReferenceEqualityComparer.Instance);
    private readonly HashSet<PdfDictionary> _masksApplied = new(ReferenceEqualityComparer.Instance);

    private SortedSet<int> UsesOf(PdfDictionary font)
    {
        if (!FontUses.TryGetValue(font, out var used)) FontUses[font] = used = [];
        return used;
    }

    private void ScanProcedures(PdfDictionary font, PdfDictionary? scope, string where, bool painted, int depth)
    {
        if (_proceduresScanned.TryGetValue(font, out bool done) && (done || !painted)) return;
        _proceduresScanned[font] = painted;
        var resources = _doc.Dict(font, "Resources") ?? scope;
        foreach (var procedure in Entries(font, "CharProcs").OfType<PdfStream>()) ScanText(procedure, resources, where, painted, depth + 1);
    }

    private void ScanProcedure(PdfFont font, int code, PdfDictionary? scope, string where)
    {
        if (font.GlyphNameOf(code) is { } name && _doc.Stream(_doc.Dict(font.Dictionary, "CharProcs"), name) is { } procedure)
            ScanText(procedure, _doc.Dict(font.Dictionary, "Resources") ?? scope, where, true, 1);
    }

    // Tiling patterns are run by the interpreter only when a path is painted with them; text and image masks painted with one never enter the cell.
    private void ScanCell(PdfColor color, string where, PdfDictionary? scope)
    {
        if (color.Pattern is PdfStream cell && _doc.Integer(cell.Dictionary, "PatternType") == 1)
            ScanText(cell, _doc.Dict(cell.Dictionary, "Resources") ?? scope, where, true);
    }

    // The group of a soft mask is drawn when something is painted under it, which the interpreter does not follow.
    private void UseMask(ContentContext context, string where, PdfDictionary? scope)
    {
        if (context.State.SoftMask is { } mask && _masksApplied.Add(mask) && _doc.Stream(mask, "G") is { } group)
            ScanText(group, _doc.Dict(group.Dictionary, "Resources") ?? scope, where, true);
    }

    private void ScanText(PdfStream stream, PdfDictionary? resources, string where, bool painted, int depth = 0)
    {
        if (OverBudget) return;
        if (depth >= MaxScanDepth)
        {
            Add("6.1.7", where, PdfAText.TooMuchContent);
            return;
        }
        if (painted ? !_textPainted.Add(stream) : _textScanned.Contains(stream)) return;
        _textScanned.Add(stream);
        IReadOnlyList<ContentOperation> operations;
        try
        {
            byte[] data = _doc.Data(stream, MaxStreamBytes);
            _work += data.Length;
            operations = ContentParser.Parse(data, MaxOperations);
        }
        catch (PdfReadException)
        {
            Unreadable(where);
            return;
        }
        PdfDictionary? font = null;
        int mode = 0, overflow = 0;
        var saved = new Stack<(PdfDictionary? Font, int Mode)>();
        foreach (var op in operations)
        {
            var name = op.Operands.Count > 0 ? op.Operands[^1] as PdfName : null;
            switch (op.Operator)
            {
                case "q":
                    if (saved.Count < MaxSavedStates) saved.Push((font, mode));
                    else overflow++;
                    break;
                case "Q":
                    if (overflow > 0) overflow--;
                    else if (saved.Count > 0) (font, mode) = saved.Pop();
                    break;
                case "Tf" when op.Operands.Count > 1 && op.Operands[^2] is PdfName fontName:
                    font = _doc.Dict(_doc.Dict(resources, "Font"), fontName.Value);
                    break;
                case "Tr" when op.Operands.Count > 0 && op.Operands[^1] is PdfNumber render:
                    mode = (int)render.Value;
                    break;
                case "Tj" or "TJ" or "'" or "\"":
                    if (font is null) break;
                    if (mode != 3) _renderedFonts.Add(font);
                    UsesOf(font);
                    if (_doc.Name(font, "Subtype") == "Type3") ScanProcedures(font, resources, where, painted, depth);
                    break;
                case "Do" when name is not null && _doc.Stream(_doc.Dict(resources, "XObject"), name.Value) is { } xobject:
                    if (_doc.Name(xobject.Dictionary, "Subtype") == "Form") ScanText(xobject, _doc.Dict(xobject.Dictionary, "Resources") ?? resources, where, painted, depth + 1);
                    else if (_doc.Name(xobject.Dictionary, "Subtype") == "Image" && _doc.Bool(xobject.Dictionary, "ImageMask") != true)
                        CheckColorSpace(xobject.Dictionary["ColorSpace"], where, resources, painted);
                    break;
                case "sh" when name is not null:
                    CheckShading(_doc.Dict(resources, "Shading")?[name.Value], where, resources, painted);
                    break;
                case "cs" or "CS" when name is not null:
                    CheckColorSpace(_doc.Dict(resources, "ColorSpace")?[name.Value] ?? name, where, resources, painted);
                    break;
                case "gs" when name is not null && _doc.Dict(_doc.Dict(_doc.Dict(resources, "ExtGState"), name.Value), "SMask") is { } mask
                    && _doc.Stream(mask, "G") is { } group:
                    ScanText(group, _doc.Dict(group.Dictionary, "Resources") ?? resources, where, painted, depth + 1);
                    break;
            }
        }
    }
}
