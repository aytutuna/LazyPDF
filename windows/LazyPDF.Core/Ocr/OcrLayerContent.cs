using System.Text;

namespace LazyPDF.Core;

/// <summary>A word of the text layer on the page as shown, in display points (origin top-left).</summary>
internal sealed record PlacedWord(string Text, double X, double Y, double Width, double Height);

/// <summary>
/// The layer's content stream: one text object per line, in render mode 3, each word set by its
/// own Tm and Tz so that its glyphs cover its box, and a space glyph filling the gap to the next
/// word. The font size is the line's height and the baseline its bottom edge, so a selection
/// covers the line. Reading it back goes through the same format.
/// </summary>
internal static class OcrLayerContent
{
    public const string Key = "LazyPDFOcr";
    public const string FontName = "LPOcrF";
    private const double MinSize = 0.01;
    private const double MinSpace = 0.1;

    // What the layer of a page can hold: MaxWords words, about seven operations for each (a line of one word has the most).
    private const long MaxSize = 16L << 20;
    private const int MaxOperations = 8 * PdfOcrLayer.MaxWords;

    /// <summary>Words in pixels to lines on the page as shown. A line takes the median top and bottom of its words, so its glyphs share a baseline.</summary>
    public static List<List<PlacedWord>> Layout(IReadOnlyList<OcrWord> words, int pixelWidth, int pixelHeight, PageGeometry geometry)
    {
        double sx = geometry.Width / pixelWidth, sy = geometry.Height / pixelHeight;
        var usable = words.Take(PdfOcrLayer.MaxWords).Where(w => IsFinite(w.Box)).Select(w => w with { Text = Clean(w.Text) }).Where(w => w.Text.Length > 0).ToList();
        var lines = new List<List<PlacedWord>>();
        foreach (var line in OcrText.Lines(usable))
        {
            var row = line.Words.Where(w => w.Text.Length > 0).ToList();
            double top = Median(row.Select(w => w.Box.Y)) * sy, bottom = Median(row.Select(w => w.Box.Bottom)) * sy;
            if (!(bottom - top > MinSize)) continue;
            lines.Add([.. row.Select(w => new PlacedWord(w.Text, w.Box.X * sx, top, w.Box.Width * sx, bottom - top))]);
        }
        return lines;
    }

    public static byte[] Build(List<List<PlacedWord>> lines, PageGeometry geometry, double userUnit, GlyphlessCodes codes)
    {
        var writer = new ContentWriter().Save();
        foreach (var line in lines)
        {
            double size = line[0].Height / userUnit;
            writer.BeginText().TextRenderMode(3).Font(FontName, size);
            for (int i = 0; i < line.Count; i++)
            {
                var word = line[i];
                Place(writer, geometry, word, codes.Bytes(OcrVisualOrder.Flip(word.Text)), word.Width);
                if (i + 1 < line.Count)
                {
                    double gap = Math.Max(line[i + 1].X - (word.X + word.Width), MinSpace * word.Height);
                    Place(writer, geometry, word with { X = word.X + word.Width }, codes.Bytes(" "), gap);
                }
            }
            writer.EndText();
        }
        return writer.Restore().ToArray();
    }

    // Tz stretches the half-em glyphs of the string across the width asked for.
    private static void Place(ContentWriter writer, PageGeometry geometry, PlacedWord word, byte[] encoded, double width)
    {
        var (x, y) = geometry.ToUser(word.X, word.Y + word.Height);
        var (rx, ry) = geometry.ToUser(word.X + 1, word.Y + word.Height);
        var (ux, uy) = geometry.ToUser(word.X, word.Y + word.Height - 1);
        double right = Math.Sqrt((rx - x) * (rx - x) + (ry - y) * (ry - y)), up = Math.Sqrt((ux - x) * (ux - x) + (uy - y) * (uy - y));
        double scale = 100 * width / (GlyphlessFont.GlyphWidth / 1000.0 * word.Height * (encoded.Length / 2));
        writer.Op("Tz", scale)
              .TextMatrix(new PdfMatrix((rx - x) / right, (ry - y) / right, (ux - x) / up, (uy - y) / up, x, y))
              .Show(encoded);
    }

    /// <summary>
    /// The geometry the stream was written in: the rotation under which its first text matrix runs
    /// along the display's x axis. After the page's /Rotate changes, lines and heights are only
    /// meaningful in that frame; <paramref name="current"/> is returned when no rotation fits.
    /// </summary>
    public static PageGeometry WrittenIn(PdfDocument document, PdfPage page, PdfStream stream, PageGeometry current)
    {
        var tm = Operations(document, stream).FirstOrDefault(o => o.Operator == "Tm" && o.Operands.Count == 6);
        if (tm is null) return current;
        double a = tm.Number(0) ?? 1, b = tm.Number(1) ?? 0, norm = Math.Sqrt(a * a + b * b);
        foreach (int rotate in new[] { current.Rotation, 0, 90, 180, 270 })
        {
            var candidate = new PageGeometry(page.CropBox, rotate, page.UserUnit);
            var (x0, y0) = candidate.ToUser(0, 0);
            var (x1, y1) = candidate.ToUser(1, 0);
            double dx = x1 - x0, dy = y1 - y0, length = Math.Sqrt(dx * dx + dy * dy);
            if (Math.Abs(dx / length - a / norm) < 1e-3 && Math.Abs(dy / length - b / norm) < 1e-3) return candidate;
        }
        return current;
    }

    /// <summary>The lines of a layer stream. Words are in display points; a stream that does not follow the format gives what could be read.</summary>
    public static List<List<PlacedWord>> Read(PdfDocument document, PdfPage page, PdfStream stream, PageGeometry geometry)
    {
        var lines = new List<List<PlacedWord>>();
        PdfFont? font = null;
        double size = 0, scale = 100;
        PdfMatrix matrix = PdfMatrix.Identity;
        int words = 0;
        foreach (var op in Operations(document, stream))
        {
            if (words >= PdfOcrLayer.MaxWords) break;
            switch (op.Operator)
            {
                case "BT":
                    lines.Add([]);
                    break;
                case "Tf" when op.Operands.Count == 2 && op.Operands[0] is PdfName name:
                    font = FontOf(document, page, name.Value);
                    size = op.Number(1) ?? 0;
                    break;
                case "Tz":
                    scale = op.Number(0) ?? 100;
                    break;
                case "Tm" when op.Operands.Count == 6:
                    matrix = new PdfMatrix(op.Number(0) ?? 1, op.Number(1) ?? 0, op.Number(2) ?? 0, op.Number(3) ?? 1, op.Number(4) ?? 0, op.Number(5) ?? 0);
                    break;
                case "Tj" when lines.Count > 0 && op.Operands.Count == 1 && op.Operands[0] is PdfString s && s.Bytes.Length >= 2:
                    if (s.Bytes is [0, 0x20]) break;
                    double width = GlyphlessFont.GlyphWidth / 1000.0 * size * (s.Bytes.Length / 2) * scale / 100;
                    var (x1, y1) = (matrix.E, matrix.F);
                    var (x2, y2) = (matrix.E + matrix.A * width + matrix.C * size, matrix.F + matrix.B * width + matrix.D * size);
                    var box = geometry.ToDisplay(new PdfRect(x1, y1, x2, y2));
                    string text = font is null ? Encoding.BigEndianUnicode.GetString(s.Bytes) : font.ToText(s.Bytes);
                    lines[^1].Add(new PlacedWord(OcrVisualOrder.Flip(text), box.X, box.Y, box.Width, box.Height));
                    words++;
                    break;
            }
        }
        lines.RemoveAll(l => l.Count == 0);
        return lines;
    }

    // A stream that inflates past the size or holds more operations is a PdfReadException, not a layer.
    private static IReadOnlyList<ContentOperation> Operations(PdfDocument document, PdfStream stream) =>
        ContentParser.Parse(document.Data(stream, MaxSize), MaxOperations);

    public static PdfFont? FontOf(PdfDocument document, PdfPage page, string name) =>
        document.Dict(document.Dict(page.Resources, "Font"), name) is { } dictionary ? PdfFont.Get(document, dictionary) : null;

    public static PdfReference AddStream(PdfDocument document, byte[] content, string language)
    {
        var marker = new PdfDictionary();
        marker["Lang"] = new PdfString(Encoding.ASCII.GetBytes(language), false);
        var dictionary = new PdfDictionary();
        dictionary[Key] = marker;
        dictionary["Filter"] = new PdfName("FlateDecode");
        return document.Add(new PdfStream(dictionary, PdfFilterEncoders.Flate(content)));
    }

    /// <summary>The font objects (ISO 32000-1 9.7): Type0 over a CIDFontType2 that has the one empty glyph.</summary>
    public static PdfReference AddFont(PdfDocument document, GlyphlessCodes codes)
    {
        byte[] program = GlyphlessFont.Program;
        var programDictionary = new PdfDictionary();
        programDictionary["Length1"] = new PdfNumber(program.Length);
        programDictionary["Filter"] = new PdfName("FlateDecode");
        var file = document.Add(new PdfStream(programDictionary, PdfFilterEncoders.Flate(program)));

        // The map is already deflated, by hand, in the font class.
        var mapDictionary = new PdfDictionary();
        mapDictionary["Filter"] = new PdfName("FlateDecode");
        var map = document.Add(new PdfStream(mapDictionary, GlyphlessFont.CidToGidMap));

        var unicodeDictionary = new PdfDictionary();
        unicodeDictionary["Filter"] = new PdfName("FlateDecode");
        var toUnicode = document.Add(new PdfStream(unicodeDictionary, PdfFilterEncoders.Flate(Encoding.ASCII.GetBytes(codes.ToUnicodeCMap()))));

        // The descent is -1, not the program's 0: PDFKit reads no text from a font whose descriptor and hhea both say 0.
        var descriptor = new PdfDictionary();
        descriptor["Type"] = new PdfName("FontDescriptor");
        descriptor["FontName"] = new PdfName(GlyphlessFont.FontName);
        descriptor["Flags"] = new PdfNumber(5);
        descriptor["FontBBox"] = Numbers(0, 0, GlyphlessFont.GlyphWidth, GlyphlessFont.UnitsPerEm);
        descriptor["ItalicAngle"] = new PdfNumber(0);
        descriptor["Ascent"] = new PdfNumber(GlyphlessFont.UnitsPerEm);
        descriptor["Descent"] = new PdfNumber(-1);
        descriptor["CapHeight"] = new PdfNumber(GlyphlessFont.UnitsPerEm);
        descriptor["StemV"] = new PdfNumber(80);
        descriptor["FontFile2"] = file;

        var system = new PdfDictionary();
        system["Registry"] = new PdfString("Adobe"u8.ToArray(), false);
        system["Ordering"] = new PdfString("Identity"u8.ToArray(), false);
        system["Supplement"] = new PdfNumber(0);

        var cidFont = new PdfDictionary();
        cidFont["Type"] = new PdfName("Font");
        cidFont["Subtype"] = new PdfName("CIDFontType2");
        cidFont["BaseFont"] = new PdfName(GlyphlessFont.FontName);
        cidFont["CIDSystemInfo"] = system;
        cidFont["FontDescriptor"] = document.Add(descriptor);
        cidFont["DW"] = new PdfNumber(GlyphlessFont.GlyphWidth);
        cidFont["CIDToGIDMap"] = map;

        var font = new PdfDictionary();
        font["Type"] = new PdfName("Font");
        font["Subtype"] = new PdfName("Type0");
        font["BaseFont"] = new PdfName(GlyphlessFont.FontName);
        font["Encoding"] = new PdfName("Identity-H");
        font["DescendantFonts"] = new PdfArray([document.Add(cidFont)]);
        font["ToUnicode"] = toUnicode;
        return document.Add(font);
    }

    public static string Clean(string text)
    {
        var sb = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            if (i + 1 < text.Length && char.IsSurrogatePair(text[i], text[i + 1])) sb.Append(text[i]).Append(text[++i]);
            else sb.Append(char.IsSurrogate(text[i]) ? '�' : text[i]);
        }
        return OcrText.CleanLine(sb.ToString().Replace('\t', ' '));
    }

    private static PdfArray Numbers(params double[] values) => new([.. values.Select(v => (PdfObject)new PdfNumber(v))]);

    private static bool IsFinite(OcrBox box) => double.IsFinite(box.X) && double.IsFinite(box.Y) && double.IsFinite(box.Width) && double.IsFinite(box.Height);

    private static double Median(IEnumerable<double> values)
    {
        var sorted = values.Order().ToList();
        int mid = sorted.Count / 2;
        return sorted.Count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
    }
}
