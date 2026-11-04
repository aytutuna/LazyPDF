namespace LazyPDF.Core;

/// <summary>
/// The glyph procedures of a Type 3 font. A procedure paints where it pleases (ISO 32000-1 9.6.5), so the font is understood
/// only when every procedure paints shapes and bitmaps and nothing that leads further (forms, shadings, patterns, text),
/// and a glyph is taken out when its ink meets a mark, wherever the box of the glyph is.
/// </summary>
internal static class RedactionGlyphs
{
    private const long MaxProcedure = 16L << 20;

    private const int MaxProcedures = 4096;

    // Wider than any glyph is: the box the scan tests runs from the origin by the width, and a larger one moves its core off the ink (9.7.4.3).
    private const double MaxWidth = 2000;

    // A line or a rectangle with no extent is a hairline to a viewer, so it gets a width of its own (em) to be tested.
    private const double Hairline = 0.001;

    /// <summary>
    /// Whether the widths of the font are the ones a viewer uses. The advance follows /Widths (9.6.2.1) or /W and /DW (9.7.4.3),
    /// within /FirstChar and /LastChar; past them, or with none, a viewer takes the metrics of its own substitute, which the scan
    /// cannot know unless the font is one of the standard 14 or carries its program.
    /// </summary>
    public static bool Measured(PdfDocument document, PdfDictionary dictionary)
    {
        if (document.Name(dictionary, "Subtype") == "Type0") return Composite(document, dictionary);
        if (document.Number(document.Dict(dictionary, "FontDescriptor"), "MissingWidth") is { } missing && !Fine(missing)) return false;
        if (!dictionary.ContainsKey("Widths"))
        {
            var font = PdfFont.Get(document, dictionary);
            return !font.IsType3 && (font.IsEmbedded || Standard14.Find(font.Name) is not null);
        }
        if (document.Array(dictionary, "Widths") is not { } widths || document.Integer(dictionary, "FirstChar") is not { } first || document.Integer(dictionary, "LastChar") is not { } last) return false;
        return first >= 0 && last <= 255 && widths.Items.Count == last - first + 1 && widths.Items.All(w => document.Resolve(w) is PdfNumber { Value: var v } && Fine(v));
    }

    private static bool Fine(double width) => width is >= 0 and <= MaxWidth;

    private static bool Composite(PdfDocument document, PdfDictionary dictionary)
    {
        if (document.Array(dictionary, "DescendantFonts") is not { Items: [var only] } || document.Resolve(only) is not PdfDictionary cid) return false;
        if (cid.ContainsKey("DW") && !Fine(document.Number(cid, "DW") ?? -1)) return false;
        if (!cid.ContainsKey("W")) return true;
        if (document.Array(cid, "W") is not { } list) return false;
        var items = list.Items.Select(document.Resolve).ToList();
        // c [w1 w2 ...] or c1 c2 w (9.7.4.3)
        for (int i = 0; i < items.Count;)
        {
            if (i + 1 >= items.Count || items[i] is not PdfNumber) return false;
            if (items[i + 1] is PdfArray run)
            {
                if (!run.Items.All(w => document.Resolve(w) is PdfNumber { Value: var v } && Fine(v))) return false;
                i += 2;
            }
            else if (i + 2 < items.Count && items[i + 1] is PdfNumber && items[i + 2] is PdfNumber { Value: var width } && Fine(width)) i += 3;
            else return false;
        }
        return true;
    }

    // Every entry of /CharProcs counts, not only those the encoding reaches: PdfFont stops reading /Differences at a limit a viewer may not have.
    public static bool Plain(PdfDocument document, PdfDictionary dictionary)
    {
        if (document.Dict(dictionary, "CharProcs") is not { } procedures) return true;
        if (procedures.Count > MaxProcedures) return false;
        // PdfFont ignores a matrix that does not scale x, so the ink would be measured in another space than the one drawn.
        if (dictionary.ContainsKey("FontMatrix") && (!RedactionSyntax.IsMatrix(document, dictionary, "FontMatrix")
            || PdfMatrix.FromArray(document.Array(dictionary, "FontMatrix"), document.Resolve) is not { A: not 0 })) return false;
        // PdfFont stops at this many items of /Differences; a viewer that reads on picks other procedures than the ones measured.
        if (document.Array(document.Dict(dictionary, "Encoding"), "Differences") is { Items.Count: > MaxProcedures }) return false;
        var font = PdfFont.Get(document, dictionary);
        return procedures.Entries.All(e => document.Resolve(e.Value) is not PdfStream procedure || Ink(document, font, procedure) is not null);
    }

    public static PdfStream? Procedure(PdfDocument document, PdfFont font, int code) =>
        font.GlyphNameOf(code) is { } name && document.Dict(font.Dictionary, "CharProcs") is { } procedures ? document.Resolve(procedures[name]) as PdfStream : null;

    // The ink of a procedure in em, a point at the origin when it paints nothing; null when it holds more than a plain glyph does.
    public static PdfRect? Ink(PdfDocument document, PdfFont font, PdfStream procedure)
    {
        byte[] data;
        IReadOnlyList<ContentOperation> operations;
        try
        {
            data = document.Data(procedure, MaxProcedure);
            operations = ContentParser.Parse(data);
        }
        catch (PdfReadException)
        {
            return null;
        }
        if (!RedactionSyntax.Whole(data, operations)) return null;
        foreach (var op in operations)
        {
            if (!RedactionSyntax.Valid(op) || !RedactionSyntax.InGlyph(op.Operator)) return null;
            if (op.Operator == "BI" && !RedactionSyntax.Fits(document, op, data, _ => null)) return null;
        }
        var ink = new InkVisitor();
        // A procedure is not a form: a /Matrix or /BBox on its stream means nothing, so it is run without the keys.
        var interpreter = new ContentInterpreter(document);
        interpreter.Run(new PdfStream(new PdfDictionary(), data), ink, font.FontMatrix);
        return interpreter.IsTruncated ? null : ink.Box;
    }

    private sealed class InkVisitor : ContentVisitor
    {
        private double _left = double.MaxValue, _bottom = double.MaxValue, _right = double.MinValue, _top = double.MinValue;

        public PdfRect Box => _left > _right ? default
            : new PdfRect(_left - (_left == _right ? Hairline : 0), _bottom - (_bottom == _top ? Hairline : 0), _right + (_left == _right ? Hairline : 0), _top + (_bottom == _top ? Hairline : 0));

        private void Add(PdfRect box) =>
            (_left, _bottom, _right, _top) = (Math.Min(_left, box.Left), Math.Min(_bottom, box.Bottom), Math.Max(_right, box.Right), Math.Max(_top, box.Top));

        public override void PaintPath(ContentContext context, PathInfo path)
        {
            if (path.Fill || path.Stroke || path.Clips) Add(path.InkBounds);
        }

        public override void PaintImage(ContentContext context, ImageInfo image) => Add(image.Bounds);
    }
}
