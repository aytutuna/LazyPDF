namespace LazyPDF.Core;

// Text in content the interpreter does not run: the soft mask groups of graphics states and the glyph procedures of Type 3 fonts. Nothing
// is decoded there, so a font that shows text is held to the font rules with no codes noted for it.
internal sealed partial class PdfAChecker
{
    private const int MaxSavedStates = 256;

    private readonly HashSet<PdfStream> _textScanned = new(ReferenceEqualityComparer.Instance);

    private SortedSet<int> UsesOf(PdfDictionary font, string where, PdfDictionary? scope, int depth = 0)
    {
        if (FontUses.TryGetValue(font, out var used)) return used;
        FontUses[font] = used = [];
        if (_doc.Name(font, "Subtype") == "Type3")
        {
            var resources = _doc.Dict(font, "Resources") ?? scope;
            foreach (var procedure in Entries(font, "CharProcs").OfType<PdfStream>()) ScanText(procedure, resources, where, depth + 1);
        }
        return used;
    }

    private void ScanText(PdfStream stream, PdfDictionary? resources, string where, int depth = 0)
    {
        if (OverBudget) return;
        if (depth >= MaxScanDepth)
        {
            Add("6.1.7", where, PdfAText.TooMuchContent);
            return;
        }
        if (!_textScanned.Add(stream)) return;
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
                case "Tf" when op.Operands.Count > 1 && op.Operands[^2] is PdfName name:
                    font = _doc.Dict(_doc.Dict(resources, "Font"), name.Value);
                    break;
                case "Tr" when op.Operands.Count > 0 && op.Operands[^1] is PdfNumber render:
                    mode = (int)render.Value;
                    break;
                case "Tj" or "TJ" or "'" or "\"":
                    if (font is null) break;
                    if (mode != 3) _renderedFonts.Add(font);
                    UsesOf(font, where, resources, depth);
                    break;
                case "Do" when op.Operands.Count > 0 && op.Operands[^1] is PdfName xobject
                    && _doc.Stream(_doc.Dict(resources, "XObject"), xobject.Value) is { } painted:
                    if (_doc.Name(painted.Dictionary, "Subtype") == "Form") ScanText(painted, _doc.Dict(painted.Dictionary, "Resources") ?? resources, where, depth + 1);
                    else if (_doc.Name(painted.Dictionary, "Subtype") == "Image" && _doc.Bool(painted.Dictionary, "ImageMask") != true)
                        CheckColorSpace(painted.Dictionary["ColorSpace"], where, resources, true);
                    break;
            }
        }
    }
}
