using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Ocr/OcrGolden.swift. One line of input is "<op> <rest>" (the format is at the top of
// ocr-input.txt): the glyphless font and its code tables, the reading order of words, the content stream of a layer on a
// page, the objects Add writes, and the kind of a page, all as text. Numbers go through PdfNumber, which both sides write alike.
internal static class OcrGolden
{
    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            int space = line.IndexOf(' ');
            string op = space < 0 ? line : line[..space];
            string rest = space < 0 ? "" : line[(space + 1)..];
            output.Append("> ").Append(line.Length > 160 ? line[..160] + "..." : line).Append('\n');
            foreach (string result in Op(op, rest)) output.Append("< ").Append(result).Append('\n');
        }
        return output.ToString();
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        try
        {
            switch (op)
            {
                case "font": return Font(rest).ToList();
                case "cmap": return CMapOf(rest).ToList();
                case "flip": return [U(OcrVisualOrder.Flip(Str(rest)))];
                case "page": return PageOf(rest).ToList();
                case "place": return Place(rest).ToList();
                case "add": return Add(rest).ToList();
                case "triage": return Triage(rest);
                case "layer": return Layer(rest);
                case "correct": return Correct(rest);
                default: return [$"unknown op {op}"];
            }
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {e.Message}"];
        }
    }

    private static string N(double v) => new PdfNumber(v).Text;

    // UTF-16 units in hex, so that no character is lost to the file's encoding.
    private static string U(string text) => string.Join(" ", text.Select(c => ((int)c).ToString("X4")));

    private static string Hex(byte[] bytes, int from, int count) => string.Concat(bytes.Skip(from).Take(count).Select(b => b.ToString("x2")));

    private static string Esc(string text)
    {
        var sb = new StringBuilder();
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '\n': sb.Append(@"\n"); break;
                case '\t': sb.Append(@"\t"); break;
                default:
                    if (c < 0x20 || c >= 0x7F) sb.Append(@"\u").Append(((int)c).ToString("X4"));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    // \uXXXX, \xHH, \n, \t and \\ in a string of the input.
    private static string Str(string text)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] != '\\' || i + 1 >= text.Length)
            {
                sb.Append(text[i]);
                continue;
            }
            char c = text[++i];
            switch (c)
            {
                case 'n': sb.Append('\n'); break;
                case 't': sb.Append('\t'); break;
                case 'u':
                    sb.Append((char)Convert.ToInt32(text.Substring(i + 1, 4), 16));
                    i += 4;
                    break;
                case 'x':
                    sb.Append((char)Convert.ToInt32(text.Substring(i + 1, 2), 16));
                    i += 2;
                    break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    private static double D(string text) => double.Parse(text, CultureInfo.InvariantCulture);

    // "text@x,y,width,height" or "text@x,y,width,height,confidence".
    private static OcrWord Word(string text)
    {
        int at = text.LastIndexOf('@');
        string[] n = text[(at + 1)..].Split(',');
        var box = new OcrBox(D(n[0]), D(n[1]), D(n[2]), D(n[3]));
        return n.Length > 4 ? new OcrWord(Str(text[..at]), box, float.Parse(n[4], CultureInfo.InvariantCulture)) : new OcrWord(Str(text[..at]), box);
    }

    private static List<OcrWord> Words(IEnumerable<string> parts) => [.. parts.Where(p => p.Length > 0).Select(Word)];

    private static string[] Split(string rest) => rest.Split(" ;; ");

    private static IEnumerable<string> Font(string kind)
    {
        switch (kind)
        {
            case "program":
            case "map":
                byte[] bytes = kind == "program" ? GlyphlessFont.Program : GlyphlessFont.CidToGidMap;
                yield return $"length {bytes.Length}";
                for (int i = 0; i < bytes.Length; i += 64) yield return Hex(bytes, i, 64);
                break;
            case "ranges":
                foreach (string line in GlyphlessFont.IdentityRanges.Value.Split('\n')) yield return line;
                break;
            default:
                yield return $"unknown font {kind}";
                break;
        }
    }

    // cmap <text>|<text>...: the codes of texts and the ToUnicode map apart from the ranges that never change.
    private static IEnumerable<string> CMapOf(string rest)
    {
        var texts = rest.Split('|').Select(Str).ToList();
        var codes = GlyphlessCodes.For(texts);
        yield return "supplementary " + string.Join(" ", codes.Supplementary.Select(c => c.ToString("X")));
        foreach (string text in texts)
        {
            yield return "codes " + string.Join(" ", codes.Codes(text).Select(c => c.ToString("X4"))) + " covers " + (codes.Covers(text) ? "1" : "0");
            yield return "bytes " + Hex(codes.Bytes(text), 0, int.MaxValue);
        }
        string map = codes.ToUnicodeCMap();
        yield return "map " + Esc(map.Replace(GlyphlessFont.IdentityRanges.Value, "<ranges>\n"));
    }

    private static IEnumerable<string> Lines(IReadOnlyList<OcrLine> lines)
    {
        foreach (var l in lines)
        {
            yield return $"line {Esc(l.Text)} [{N(l.Box.X)} {N(l.Box.Y)} {N(l.Box.Width)} {N(l.Box.Height)}] {N(l.Confidence)} {string.Join(",", l.Words.Select(w => Esc(w.Text)))}";
        }
    }

    // page <pixel width> <pixel height> ;; <word> ;; <word> ...: lines, paragraphs and the texts of one page.
    private static IEnumerable<string> PageOf(string rest)
    {
        var parts = Split(rest);
        string[] size = parts[0].Split(' ');
        var page = OcrPage.Of(Words(parts.Skip(1)), int.Parse(size[0], CultureInfo.InvariantCulture), int.Parse(size[1], CultureInfo.InvariantCulture));
        foreach (string line in Lines(page.Lines)) yield return line;
        foreach (var p in OcrText.Paragraphs(page)) yield return $"paragraph {p.Lines.Count} {Esc(p.Text)}";
        yield return "pagetext " + Esc(OcrText.PageText(page));
        yield return "plaintext " + Esc(OcrText.PlainText([page, OcrPage.Of([], 10, 10)]));
    }

    // place <rotate> <crop box or -> <user unit> <pixel width> <pixel height> ;; <word> ...: a layer's lines on a page
    // whose media box is 400 x 600, and the content stream written for them.
    private static IEnumerable<string> Place(string rest)
    {
        var parts = Split(rest);
        string[] head = parts[0].Split(' ');
        var box = head[1] == "-" ? new PdfRect(0, 0, 400, 600) : PdfBox(head[1]);
        double unit = D(head[2]);
        var geometry = new PageGeometry(box, int.Parse(head[0], CultureInfo.InvariantCulture), unit);
        var words = Words(parts.Skip(1));
        var lines = OcrLayerContent.Layout(words, int.Parse(head[3], CultureInfo.InvariantCulture), int.Parse(head[4], CultureInfo.InvariantCulture), geometry);
        yield return $"display {N(geometry.Width)} {N(geometry.Height)}";
        foreach (var line in lines)
        {
            yield return "placed " + string.Join(" | ", line.Select(w => $"{Esc(w.Text)} [{N(w.X)} {N(w.Y)} {N(w.Width)} {N(w.Height)}]"));
        }
        var codes = GlyphlessCodes.For(lines.SelectMany(l => l).Select(w => w.Text));
        yield return "content " + Esc(Encoding.Latin1.GetString(OcrLayerContent.Build(lines, geometry, unit > 0 ? unit : 1, codes)));
    }

    private static PdfRect PdfBox(string text)
    {
        double[] v = [.. text.Split(',').Select(D)];
        return new PdfRect(v[0], v[1], v[2], v[3]);
    }

    private static string Entries(string text) => text == "-" ? "" : text;

    // add <page entries or -> ;; <language> ;; <word> ...: Add on the scan of OcrKit, then the layer's stream and the objects of
    // the font, each as the file would write it, with the data of the streams decoded.
    private static IEnumerable<string> Add(string rest)
    {
        var parts = Split(rest);
        var document = OcrKit.Scan(1, Entries(parts[0]));
        var geometry = new PageGeometry(document.Pages[0]);
        int placed = PdfOcrLayer.Add(document, [new OcrPageWords(0, Words(parts.Skip(2)), (int)geometry.Width, (int)geometry.Height)], parts[1]);
        yield return $"placed {placed}";
        var page = document.Pages[0];
        yield return "contents " + page.Dictionary["Contents"];
        yield return "fonts " + document.Dict(page.Resources, "Font");
        var items = document.Resolve(page.Dictionary["Contents"]) is PdfArray array ? array.Items : [];
        foreach (var item in items)
        {
            if (document.Resolve(item) is not PdfStream stream || !stream.Dictionary.ContainsKey("LazyPDFOcr")) continue;
            yield return "layer " + stream.Dictionary;
            yield return "stream " + Esc(Encoding.Latin1.GetString(document.Data(stream)));
        }
        var font = document.Dict(document.Dict(page.Resources, "Font"), "LPOcrF");
        if (font is null) yield break;
        yield return "font " + font;
        var cid = document.Resolve(((PdfArray)document.Resolve(font["DescendantFonts"])!).Items[0]) as PdfDictionary;
        yield return "cidfont " + cid;
        var descriptor = document.Dict(cid, "FontDescriptor");
        yield return "descriptor " + descriptor;
        byte[] program = document.Data((PdfStream)document.Resolve(descriptor!["FontFile2"])!);
        yield return "program " + (program.AsSpan().SequenceEqual(GlyphlessFont.Program) ? "same" : "different");
        byte[] map = document.Data((PdfStream)document.Resolve(cid!["CIDToGIDMap"])!);
        yield return "map " + (map.AsSpan().SequenceEqual(GlyphlessFont.CidToGidMapData()) ? "same" : "different");
        string toUnicode = Encoding.ASCII.GetString(document.Data((PdfStream)document.Resolve(font["ToUnicode"])!));
        yield return "tounicode " + Esc(toUnicode.Replace(GlyphlessFont.IdentityRanges.Value, "<ranges>\n"));
    }

    private static IEnumerable<string> WordLines(PdfDocument document)
    {
        foreach (var w in PdfOcrLayer.Words(document, document.Pages[0]))
        {
            yield return $"word {w.Index} {Esc(w.Text)} [{N(w.Box.X)} {N(w.Box.Y)} {N(w.Box.Width)} {N(w.Box.Height)}]";
        }
    }

    // layer <page entries or -> ;; <content>: the words read from a layer stream written by hand with that content.
    private static IEnumerable<string> Layer(string rest)
    {
        var parts = Split(rest);
        var document = OcrKit.Scan(1, Entries(parts[0]));
        OcrKit.AddLayer(document, Encoding.Latin1.GetString(Golden.Unescape(parts[1])));
        return WordLines(document).ToList();
    }

    // correct <page entries or -> ;; <index> ;; <text> ;; <word> ...: Add on the scan, then Correct; the words read back, the
    // layer's stream decoded and the characters beyond the BMP the font carries, by code.
    private static IEnumerable<string> Correct(string rest)
    {
        var parts = Split(rest);
        var document = OcrKit.Scan(1, Entries(parts[0]));
        var geometry = new PageGeometry(document.Pages[0]);
        PdfOcrLayer.Add(document, [new OcrPageWords(0, Words(parts.Skip(3)), (int)geometry.Width, (int)geometry.Height)], "en");
        var page = document.Pages[0];
        PdfOcrLayer.Correct(document, page, int.Parse(parts[1], CultureInfo.InvariantCulture), Str(parts[2]));
        var result = WordLines(document).ToList();
        var items = document.Resolve(page.Dictionary["Contents"]) is PdfArray array ? array.Items : [];
        foreach (var item in items)
        {
            if (document.Resolve(item) is PdfStream stream && stream.Dictionary.ContainsKey("LazyPDFOcr")) result.Add("stream " + Esc(Encoding.Latin1.GetString(document.Data(stream))));
        }
        var font = OcrLayerContent.FontOf(document, page, "LPOcrF");
        result.Add("supplementary " + (font is null ? "none" : string.Join(" ", GlyphlessCodes.From(font).Supplementary.Select(c => c.ToString("X")))));
        return result;
    }

    // triage <page entries or -> ;; <content>: the kind of the page of OcrKit.Scan that draws the content.
    private static IEnumerable<string> Triage(string rest)
    {
        var parts = Split(rest);
        var document = OcrKit.Scan(1, Entries(parts[0]), Encoding.Latin1.GetString(Golden.Unescape(parts[1])));
        return [OcrTriage.Classify(document, document.Pages[0]).ToString()];
    }
}
