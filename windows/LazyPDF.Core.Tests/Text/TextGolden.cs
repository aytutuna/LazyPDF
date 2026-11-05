using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Text/TextGolden.swift. One line of input is "<op> <words>" (the format is at the
// top of text-input.txt): one-page files and the fixture files turned into text pages and dumped, searches, and the
// tables of UTF-16 classification and folding that the search is built on, all as text. Numbers go through
// PdfNumber, which both sides write alike.
internal static class TextGolden
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
                case "page": return PageOp(rest, new TextPageOptions());
                case "pageopts": return PageOptions(rest);
                case "search": return Search(rest);
                case "fixture": return Fixture(rest);
                case "text": return Strings(rest);
                case "blocks": return Blocks(rest);
                default: return [$"unknown op {op}"];
            }
        }
        catch (PdfReadException e)
        {
            return [$"error {e.Problem} {e.Message}"];
        }
    }

    private static string N(double v) => new PdfNumber(v).Text;

    private static string R(PdfRect r) => $"[{N(r.Left)} {N(r.Bottom)} {N(r.Right)} {N(r.Top)}]";

    private static string Q(TextQuad q) => $"[{N(q.X0)} {N(q.Y0)} {N(q.X1)} {N(q.Y1)} {N(q.X2)} {N(q.Y2)} {N(q.X3)} {N(q.Y3)}]";

    private static string B(bool value) => value ? "1" : "0";

    // UTF-16 units in hex, so that no character is lost to the file's encoding.
    private static string U(string text) => string.Join(" ", text.Select(c => ((int)c).ToString("X4")));

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
                case '\f': sb.Append(@"\f"); break;
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
                case 'u': sb.Append((char)Convert.ToInt32(text.Substring(i + 1, 4), 16)); i += 4; break;
                case 'x': sb.Append((char)Convert.ToInt32(text.Substring(i + 1, 2), 16)); i += 2; break;
                default: sb.Append(c); break;
            }
        }
        return sb.ToString();
    }

    // {line X Y text}, {size S X Y text} and {col X TOP prefix N} stand for the content of TextTestPdf.Line and of a
    // column of lines 12 points apart.
    private static string Expand(string text)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            int close = text[i] == '{' ? text.IndexOf('}', i) : -1;
            if (close < 0)
            {
                sb.Append(text[i]);
                continue;
            }
            string body = text[(i + 1)..close];
            string[] w = body.Split(' ');
            if (w[0] == "line" && w.Length >= 4) sb.Append(Line(w[1], w[2], string.Join(' ', w[3..]), "10"));
            else if (w[0] == "size" && w.Length >= 5) sb.Append(Line(w[2], w[3], string.Join(' ', w[4..]), w[1]));
            else if (w[0] == "col" && w.Length == 5)
            {
                for (int k = 0; k < int.Parse(w[4]); k++) sb.Append(Line(w[1], (int.Parse(w[2]) - k * 12).ToString(), $"{w[3]} line {k + 1} of the column", "10"));
            }
            else
            {
                sb.Append(text[i]);
                continue;
            }
            i = close;
        }
        return sb.ToString();
    }

    private static string Line(string x, string y, string text, string size) => $"BT /F1 {size} Tf {x} {y} Td ({text}) Tj ET\\n";

    // code=hex,code=hex: the text of a code as UTF-16 units in hex, four digits each.
    private static (int, string)[] FontMap(string text)
    {
        if (text == "-" || text.Length == 0) return [];
        return [.. text.Split(',').Select(entry =>
        {
            string[] parts = entry.Split('=');
            var units = Enumerable.Range(0, parts[1].Length / 4).Select(k => (char)Convert.ToInt32(parts[1].Substring(k * 4, 4), 16));
            return (int.Parse(parts[0]), new string(units.ToArray()));
        })];
    }

    // page <pageEntries> ;; <resources> ;; <content> ;; <object>...  where an object is "font N [code=hex,...]",
    // "obj N <text>" or "stream N <entries> :: <bytes>". "-" stands for nothing, and for the resources of /F1 as object 5.
    private static PdfDocument Build(string[] fields)
    {
        string pageEntries = fields[0] == "-" ? "" : fields[0];
        string resources = fields[1] == "-" ? "/Font <</F1 5 0 R>>" : fields[1];
        byte[] content = Golden.Unescape(Expand(fields[2]));
        var objects = fields[3..];
        var pdf = new TestPdf();
        string catalog = string.Concat(objects.Where(o => o.StartsWith("catalog ", StringComparison.Ordinal)).Select(o => o[8..] + " "));
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<{resources}>> {pageEntries}>>");
        pdf.Stream(4, "", content);
        foreach (string field in objects)
        {
            if (field.StartsWith("catalog ", StringComparison.Ordinal)) continue;
            string[] w = field.Split(' ', 3);
            int number = int.Parse(w[1]);
            switch (w[0])
            {
                case "font": TextTestPdf.Font(pdf, number, FontMap(w.Length > 2 ? w[2] : "-")); break;
                case "obj": pdf.Obj(number, Expand(w[2])); break;
                case "stream":
                    int split = w[2].IndexOf(" :: ", StringComparison.Ordinal);
                    pdf.Stream(number, w[2][..split] == "-" ? "" : w[2][..split], Golden.Unescape(Expand(w[2][(split + 4)..])));
                    break;
            }
        }
        return PdfDocument.Open(pdf.Finish());
    }

    private static IEnumerable<string> PageOp(string rest, TextPageOptions options)
    {
        var document = Build(rest.Split(" ;; "));
        return DumpPage(TextPage.Create(document, document.Pages[0], options));
    }

    // pageopts <flags> ;; <page spec>: flags A (no artifacts), D (keep duplicates) and N (annotations).
    private static IEnumerable<string> PageOptions(string rest)
    {
        int split = rest.IndexOf(" ;; ", StringComparison.Ordinal);
        string flags = rest[..split];
        return PageOp(rest[(split + 4)..], new TextPageOptions(!flags.Contains('A'), !flags.Contains('D'), flags.Contains('N')));
    }

    private static IEnumerable<string> Fixture(string rest)
    {
        string[] words = rest.Split(' ');
        string path = words[0].Contains('/') ? words[0] : "Documents/" + words[0];
        byte[] file = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", path));
        var document = PdfDocument.Open(file, words[1] == "-" ? null : words[1]);
        var lines = new List<string>();
        var interpreter = new ContentInterpreter(document);
        for (int i = 0; i < document.Pages.Count; i++)
        {
            lines.Add($"page {i}");
            lines.AddRange(DumpPage(TextPage.Create(interpreter, document.Pages[i])));
        }
        return lines;
    }

    private static IEnumerable<string> DumpPage(TextPage page)
    {
        var lines = new List<string>
        {
            $"page index={page.PageIndex} box={R(page.Box)} truncated={B(page.IsTruncated)} annotations={B(page.IncludesAnnotations)} " +
            $"chars={page.Chars.Count} words={page.Words.Count} lines={page.Lines.Count} blocks={page.Blocks.Count}",
        };
        foreach (var c in page.Chars)
        {
            var rgb = c.Color;
            lines.Add($"char {c.Index} u={U(c.Text)} q={Q(c.Quad)} font={c.Font?.Name ?? "-"} size={N(c.Size)} rgb={rgb.R},{rgb.G},{rgb.B} mode={c.RenderMode} op={c.OperatorIndex} " +
                      $"form={B(c.Form is not null)} el={c.Element} off={c.Offset} mcid={(c.Mcid is { } m ? m.ToString() : "-")} art={B(c.IsArtifact)} " +
                      $"space={B(c.IsSpace)} implied={B(c.IsImplied)} rtl={B(c.IsRtl)} word={c.Word} line={c.Line}");
        }
        foreach (var w in page.Words) lines.Add($"word {w.Index} [{w.Range.Start},{w.Range.End}) u={U(w.Text)} b={R(w.Bounds)} line={w.Line}");
        foreach (var l in page.Lines)
        {
            lines.Add($"line {l.Index} [{l.Range.Start},{l.Range.End}) u={U(l.Text)} b={R(l.Bounds)} q={Q(l.Quad)} block={l.Block} before={l.Before} vertical={B(l.IsVertical)} rtl={B(l.IsRtl)}");
        }
        foreach (var b in page.Blocks) lines.Add($"block {b.Index} lines=[{b.Lines.Start},{b.Lines.End}) b={R(b.Bounds)} table={B(b.IsTable)}");
        lines.Add($"text {Esc(page.Text)}");
        lines.Add($"joined {Esc(page.GetText(new TextRange(0, page.Chars.Count), true))}");
        lines.Add($"quads {string.Join(";", page.Quads(new TextRange(0, page.Chars.Count)).Select(Q))}");
        int n = page.Chars.Count;
        if (n == 0) return lines;
        foreach (int i in new[] { 0, n / 3, n / 2, 2 * n / 3, n - 1 }.Distinct())
        {
            var (cx, cy) = page.Chars[i].Quad.Center;
            foreach (var (x, y) in new[] { (cx, cy), (cx + 3, cy - 2) })
            {
                var hit = page.HitTest(x, y);
                lines.Add($"probe {i} p={N(x)},{N(y)} hit={(hit is { } h ? $"{h.Char}/{h.Word}/{h.Line}/{N(h.Distance)}" : "-")} caret={page.CaretAt(x, y)} " +
                          $"word={Esc(TextSelection.WordAt(page, x, y).GetText())} line={Esc(TextSelection.LineAt(page, x, y).GetText())}");
            }
        }
        var first = page.Chars[0].Quad.Center;
        var last = page.Chars[n - 1].Quad.Center;
        lines.Add($"between {Esc(TextSelection.Between(page, first.X, first.Y, last.X, last.Y).GetText())}");
        var box = page.Box;
        lines.Add($"rectangle {Esc(TextSelection.InRectangle(page, new PdfRect(box.Left, box.Bottom + box.Height / 2, box.Right, box.Top)).GetText())}");
        return lines;
    }

    // search <flags> ;; <query> ;; <page spec as in "page">. Flags are c (match case), w (whole word), r (regex) and f
    // (fold diacritics), or "-".
    private static IEnumerable<string> Search(string rest)
    {
        string[] fields = rest.Split(" ;; ");
        var options = new TextSearchOptions(fields[0].Contains('c'), fields[0].Contains('w'), fields[0].Contains('r'), fields[0].Contains('f'));
        var document = Build(fields[2..]);
        var page = TextPage.Create(document, document.Pages[0]);
        var lines = new List<string>();
        try
        {
            foreach (var match in TextSearch.Find(page, Str(fields[1]), options))
            {
                lines.Add($"match [{match.Range.Start},{match.Range.End}) page={match.Page} text={Esc(match.Text)} quads={string.Join(";", match.Quads.Select(Q))}");
            }
        }
        catch (ArgumentException)
        {
            lines.Add("bad pattern");
        }
        lines.Add($"count {lines.Count}");
        return lines;
    }

    // text <flags> <string>: what the search does to one string.
    private static IEnumerable<string> Strings(string rest)
    {
        int space = rest.IndexOf(' ');
        string flags = rest[..space];
        string text = Str(rest[(space + 1)..]);
        var options = new TextSearchOptions(flags.Contains('c'), false, false, flags.Contains('f'));
        return
        [
            $"fold {U(SearchText.Fold(text, options))}",
            $"strip {U(SearchText.StripMarks(text))}",
            $"clean {U(TextNormal.Clean(text))}",
            $"collapse {U(SearchText.Collapse(text))}",
            $"class {TextBidi.ClassOf(text)}",
        ];
    }

    // blocks <kind>: for the blocks of 256 UTF-16 units below that have anything to say, the units a test is true for as
    // ranges, or what a unit becomes. Runtimes carry different versions of the Unicode data, and the blocks that got
    // letters or case pairs in versions 16 and 17 differ between them; these have not changed for years.
    private static readonly int[] StableBlocks = [0x00, 0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x1E, 0x1F, 0x20, 0x21, 0x24, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF];

    private static IEnumerable<string> Blocks(string kind)
    {
        var lines = new List<string>();
        foreach (int block in StableBlocks)
        {
            string line = kind switch
            {
                "letter" => Ranges(block, c => char.IsLetter(c)),
                "lower" => Ranges(block, c => char.IsLower(c)),
                "white" => Ranges(block, c => char.IsWhiteSpace(c)),
                "mark" => Ranges(block, c => char.GetUnicodeCategory(c) == System.Globalization.UnicodeCategory.NonSpacingMark),
                "tolower" => Changes(block, c => SearchText.Fold(c.ToString(), new TextSearchOptions())),
                "toloweri" => Changes(block, c => SearchText.Fold(c.ToString(), new TextSearchOptions(FoldDiacritics: true))),
                "strip" => Changes(block, c => SearchText.StripMarks(c.ToString())),
                "clean" => Changes(block, c => TextNormal.Clean(c.ToString())),
                _ => "",
            };
            if (line.Length > 0) lines.Add($"{block:X2} {line}");
        }
        return lines;
    }

    private static bool Surrogate(int unit) => unit is >= 0xD800 and <= 0xDFFF;

    private static string Ranges(int block, Func<char, bool> test)
    {
        var parts = new List<string>();
        int start = -1;
        for (int i = 0; i <= 256; i++)
        {
            int unit = block * 256 + i;
            bool on = i < 256 && test((char)unit);
            if (on && start < 0) start = unit;
            else if (!on && start >= 0)
            {
                parts.Add(start == unit - 1 ? $"{start:X4}" : $"{start:X4}-{unit - 1:X4}");
                start = -1;
            }
        }
        return string.Join(" ", parts);
    }

    private static string Changes(int block, Func<char, string> map)
    {
        var parts = new List<string>();
        for (int i = 0; i < 256; i++)
        {
            int unit = block * 256 + i;
            if (Surrogate(unit)) continue;
            string result = map((char)unit);
            if (result != ((char)unit).ToString()) parts.Add($"{unit:X4}>{U(result).Replace(' ', '+')}");
        }
        return string.Join(" ", parts);
    }
}
