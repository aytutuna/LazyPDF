using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// Content stream bytes from operations: parsed ones written back, or new ones built with the
/// small helpers below. Numbers are written the way <see cref="PdfNumber"/> writes them, at most
/// six decimals with no exponent.
/// </summary>
public sealed class ContentWriter
{
    private readonly MemoryStream _bytes = new();
    private readonly StringBuilder _line = new();

    public int Length => (int)_bytes.Length;

    public byte[] ToArray() => _bytes.ToArray();

    /// <summary>The operations written out one to a line; parsing the result gives the same operators and operands.</summary>
    public static byte[] Write(IEnumerable<ContentOperation> operations)
    {
        var writer = new ContentWriter();
        foreach (var operation in operations) writer.Add(operation);
        return writer.ToArray();
    }

    public ContentWriter Add(ContentOperation operation)
    {
        if (operation.Image is { } image)
        {
            _line.Append("BI");
            foreach (var (key, value) in image.Dictionary.Entries)
            {
                _line.Append(' ');
                new PdfName(key).WriteTo(_line);
                _line.Append(' ');
                value.WriteTo(_line);
            }
            _line.Append("\nID\n");
            Flush();
            _bytes.Write(image.Data);
            _line.Append("\nEI\n");
            Flush();
            return this;
        }
        return Op(operation.Operator, operation.Operands);
    }

    /// <summary>One operator with its operands.</summary>
    public ContentWriter Op(string name, IReadOnlyList<PdfObject> operands)
    {
        foreach (var operand in operands)
        {
            operand.WriteTo(_line);
            _line.Append(' ');
        }
        _line.Append(name).Append('\n');
        Flush();
        return this;
    }

    public ContentWriter Op(string name, params ReadOnlySpan<double> numbers)
    {
        foreach (double n in numbers) _line.Append(new PdfNumber(n).Text).Append(' ');
        _line.Append(name).Append('\n');
        Flush();
        return this;
    }

    private void Flush()
    {
        if (_line.Length == 0) return;
        _bytes.Write(Encoding.Latin1.GetBytes(_line.ToString()));
        _line.Clear();
    }

    public ContentWriter Save() => Op("q");

    public ContentWriter Restore() => Op("Q");

    public ContentWriter Concat(PdfMatrix m) => Op("cm", m.A, m.B, m.C, m.D, m.E, m.F);

    public ContentWriter Rect(double x, double y, double width, double height) => Op("re", x, y, width, height);

    public ContentWriter MoveTo(double x, double y) => Op("m", x, y);

    public ContentWriter LineTo(double x, double y) => Op("l", x, y);

    public ContentWriter CurveTo(double x1, double y1, double x2, double y2, double x3, double y3) => Op("c", x1, y1, x2, y2, x3, y3);

    public ContentWriter Close() => Op("h");

    public ContentWriter Fill() => Op("f");

    public ContentWriter FillEvenOdd() => Op("f*");

    public ContentWriter Stroke() => Op("S");

    public ContentWriter FillAndStroke() => Op("B");

    public ContentWriter EndPath() => Op("n");

    /// <summary>Clips to the current path and ends it.</summary>
    public ContentWriter Clip() => Op("W").Op("n");

    public ContentWriter LineWidth(double width) => Op("w", width);

    public ContentWriter Dash(double on, double off) =>
        Op("d", [new PdfArray([new PdfNumber(on), new PdfNumber(off)]), new PdfNumber(0L)]);

    public ContentWriter FillGray(double g) => Op("g", g);

    public ContentWriter FillRgb(double r, double g, double b) => Op("rg", r, g, b);

    public ContentWriter FillCmyk(double c, double m, double y, double k) => Op("k", c, m, y, k);

    public ContentWriter StrokeGray(double g) => Op("G", g);

    public ContentWriter StrokeRgb(double r, double g, double b) => Op("RG", r, g, b);

    public ContentWriter StrokeCmyk(double c, double m, double y, double k) => Op("K", c, m, y, k);

    /// <summary>Selects the /ExtGState resource <paramref name="name"/>.</summary>
    public ContentWriter GraphicsState(string name) => Op("gs", [new PdfName(name)]);

    public ContentWriter BeginText() => Op("BT");

    public ContentWriter EndText() => Op("ET");

    public ContentWriter Font(string name, double size) => Op("Tf", [new PdfName(name), new PdfNumber(size)]);

    /// <summary>Moves to the start of the next line, offset from the start of the current one.</summary>
    public ContentWriter MoveText(double x, double y) => Op("Td", x, y);

    public ContentWriter TextMatrix(PdfMatrix m) => Op("Tm", m.A, m.B, m.C, m.D, m.E, m.F);

    public ContentWriter TextRenderMode(int mode) => Op("Tr", mode);

    public ContentWriter CharSpacing(double spacing) => Op("Tc", spacing);

    public ContentWriter WordSpacing(double spacing) => Op("Tw", spacing);

    /// <summary>Shows text already encoded for the current font, as a hex string.</summary>
    public ContentWriter Show(ReadOnlySpan<byte> encoded) => Op("Tj", [new PdfString(encoded.ToArray(), isHex: true)]);

    /// <summary>
    /// Shows the line of text in <paramref name="font"/> set in <paramref name="size"/>, in display order. A shaper's offsets and
    /// advances that differ from the font's become <c>TJ</c> adjustments and <c>Ts</c> rises; a line whose glyphs do not map
    /// one to one to its characters is wrapped in marked content with /ActualText, so that copying gives the logical text.
    /// </summary>
    public ContentWriter Show(PdfDrawFont font, string text, double size) => Show(font, font.Shaped(text), text, size);

    /// <summary>Shows a run whose direction the layout has already resolved.</summary>
    internal ContentWriter ShowRun(PdfDrawFont font, string text, bool rightToLeft, double size) => Show(font, font.Run(text, rightToLeft), text, size);

    private ContentWriter Show(PdfDrawFont font, ShapedLine? line, string text, double size)
    {
        if (line is null) return Show(font.Encode(text));
        if (line.NeedsActualText)
        {
            var bytes = new List<byte> { 0xFE, 0xFF };
            bytes.AddRange(System.Text.Encoding.BigEndianUnicode.GetBytes(line.ActualText));
            Op("BDC", [new PdfName("Span"), new PdfDictionary { ["ActualText"] = new PdfString([.. bytes], isHex: true) }]);
        }

        var items = new List<PdfObject>();
        var codes = new List<byte>();
        bool adjusted = false;
        double carry = 0, rise = 0;
        void Adjust()
        {
            carry = Math.Round(carry, 3);
            if (carry == 0) return;
            if (codes.Count > 0) items.Add(new PdfString([.. codes], isHex: true));
            codes.Clear();
            items.Add(new PdfNumber(carry));
            carry = 0;
            adjusted = true;
        }
        void Close()
        {
            if (codes.Count > 0) items.Add(new PdfString([.. codes], isHex: true));
            codes.Clear();
            if (items.Count > 0) Op(adjusted ? "TJ" : "Tj", [adjusted ? new PdfArray(items) : items[0]]);
            items = [];
            adjusted = false;
        }

        foreach (var entry in line.Glyphs)
        {
            var glyph = entry.Shaped;
            double lift = Math.Round(glyph.YOffset * size / 1000, 3);
            if (lift != rise)
            {
                Close();
                Op("Ts", lift);
                rise = lift;
            }
            // A TJ number moves the pen left by that much, so the glyph is drawn after -XOffset and the pen then put where the shaper wants it.
            carry -= glyph.XOffset;
            Adjust();
            codes.AddRange(font.CodeOf(line, entry));
            double drift = font.CodeWidth(glyph.Glyph) - glyph.Advance;
            carry += glyph.XOffset + (Math.Abs(drift) > 0.5 ? drift : 0);
        }
        Close();
        if (rise != 0) Op("Ts", 0);
        return line.NeedsActualText ? EndMarked() : this;
    }

    /// <summary>Paints the /XObject resource <paramref name="name"/>.</summary>
    public ContentWriter Paint(string name) => Op("Do", [new PdfName(name)]);

    /// <summary>Paints an image or form so that its unit square fills the matrix's parallelogram.</summary>
    public ContentWriter Paint(string name, PdfMatrix placement) => Save().Concat(placement).Paint(name).Restore();

    public ContentWriter BeginMarked(string tag) => Op("BMC", [new PdfName(tag)]);

    /// <summary>Opens marked content with an inline property dictionary holding /MCID.</summary>
    public ContentWriter BeginMarked(string tag, int mcid)
    {
        var properties = new PdfDictionary { ["MCID"] = new PdfNumber(mcid) };
        return Op("BDC", [new PdfName(tag), properties]);
    }

    public ContentWriter EndMarked() => Op("EMC");

    /// <summary>The bytes as they are, for an operator the helpers do not cover.</summary>
    public ContentWriter Raw(string text)
    {
        _line.Append(text);
        if (!text.EndsWith('\n')) _line.Append('\n');
        Flush();
        return this;
    }
}
