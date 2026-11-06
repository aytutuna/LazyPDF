using System.Security.Cryptography;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Compare/CompareGolden.swift. One line of input is "<op> <words>" (the format is at the
// top of compare-input.txt): edit scripts, comparisons of made files and pixel comparisons of made pages, dumped as text.
// Numbers go through PdfNumber, which both sides write alike.
internal static class CompareGolden
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
        switch (op)
        {
            case "diff": return Diff(rest);
            case "compare": return Compare(rest);
            case "pixel": return Pixel(rest);
            default: return [$"unknown op {op}"];
        }
    }

    private static string N(double v) => new PdfNumber(v).Text;

    private static string Esc(string text) => Golden.Escape(text);

    private static int[] Ints(string text) => text == "-" ? [] : [.. text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(int.Parse)];

    private static IEnumerable<string> Diff(string rest)
    {
        string[] parts = rest.Split(" ;; ");
        var hunks = parts.Length > 2 ? SequenceDiff.Diff(Ints(parts[0]), Ints(parts[1]), int.Parse(parts[2])) : SequenceDiff.Diff(Ints(parts[0]), Ints(parts[1]));
        if (hunks.Count == 0) return ["none"];
        return hunks.Select(h => $"hunk {h.OldStart} {h.OldCount} {h.NewStart} {h.NewCount}");
    }

    // "<flags> ;; <before> ;; <after>": flags are i (ignore case), w (white space), h (header and footer) or "-". A file is its
    // pages split by " || ", a page its lines split by " | ", "-" a page with no lines. A line is plain text, "@topic:n" for the n
    // lines CompareKit.Page makes, or "{F2 14 1 0 0} text" for a font, a size and a colour.
    private static CompareLine[][] File(string text) =>
        [.. text.Split(" || ").Select(page => page == "-" ? Array.Empty<CompareLine>() : page.Split(" | ").SelectMany(Lines).ToArray())];

    private static IEnumerable<CompareLine> Lines(string line)
    {
        if (line.StartsWith('@'))
        {
            string[] topic = line[1..].Split(':');
            return CompareKit.Page(topic[0], int.Parse(topic[1])).Select(CompareKit.L);
        }
        if (line.StartsWith('{'))
        {
            int close = line.IndexOf('}');
            string[] style = line[1..close].Split(' ');
            return [new CompareLine(line[(close + 2)..], style[0], double.Parse(style[1], System.Globalization.CultureInfo.InvariantCulture), string.Join(' ', style.Skip(2)))];
        }
        return [new CompareLine(line)];
    }

    private static IEnumerable<string> Compare(string rest)
    {
        string[] parts = rest.Split(" ;; ");
        var options = new CompareOptions(parts[0].Contains('i'), parts[0].Contains('w'), parts[0].Contains('h'));
        using var before = CompareKit.Open(CompareKit.Bytes(File(parts[1])));
        using var after = CompareKit.Open(CompareKit.Bytes(File(parts[2])));
        var result = PdfComparer.Compare(before, after, options);
        var lines = new List<string>
        {
            $"pages {result.OldPageCount} {result.NewPageCount}: " + string.Join(' ', result.Pages.Select(p => $"{p.OldIndex}/{p.NewIndex}/{N(p.Similarity)}{(p.Moved ? "/moved" : "")}")),
        };
        foreach (var c in result.Changes)
        {
            lines.Add($"change {c.Kind} {c.Area} {c.OldPage} {c.NewPage} old={Esc(c.OldText)} new={Esc(c.NewText)} detail={(c.Detail is null ? "-" : Esc(c.Detail))}");
            lines.Add($"  old {Quads(c.OldQuads)}");
            lines.Add($"  new {Quads(c.NewQuads)}");
        }
        var s = result.Summary;
        lines.Add($"summary {s.Added} {s.Removed} {s.Changed} {s.Moved} | {s.Text} {s.Format} {s.Images} {s.Annotations} {s.Pages} {s.Document} | {s.WordsAdded} {s.WordsRemoved}");
        foreach (string text in ComparisonReport.ToText(result, "old.pdf", "new.pdf").Split('\n')) lines.Add("text " + Esc(text));
        return lines;
    }

    private static string Quads(IReadOnlyList<TextQuad> quads) =>
        string.Join(" ; ", quads.Select(q => $"[{N(q.X0)} {N(q.Y0)} {N(q.X1)} {N(q.Y1)} {N(q.X2)} {N(q.Y2)} {N(q.X3)} {N(q.Y3)}]"));

    // "<before> ;; <after> ;; <dpi> [;; a]": a page is "text <seed> <scale>" and then "fill x y w h value" and "scan degrees
    // shiftX shiftY noise" in any number, the last scan turning the canvas into the picture; "a" at the end switches the
    // alignment off.
    private static IEnumerable<string> Pixel(string rest)
    {
        string[] parts = rest.Split(" ;; ");
        var options = new PixelOptions(Align: parts.Length < 4);
        var result = PixelComparer.Compare(Picture(parts[0]), Picture(parts[1]), double.Parse(parts[2], System.Globalization.CultureInfo.InvariantCulture), options);
        var lines = new List<string>();
        foreach (var d in result.Differences) lines.Add($"region {N(d.Region.X)} {N(d.Region.Y)} {N(d.Region.Width)} {N(d.Region.Height)} {d.Pixels}");
        if (lines.Count == 0) lines.Add("regions none");
        lines.Add($"similarity {N(result.Similarity)}");
        lines.Add($"alignment {N(result.Alignment.ShiftX)} {N(result.Alignment.ShiftY)} {N(result.Alignment.Degrees)}");
        lines.Add($"overlay {result.Overlay.Width} {result.Overlay.Height} {Convert.ToHexString(SHA256.HashData(result.Overlay.Rgba))}");
        return lines;
    }

    private static PdfRgbaImage Picture(string spec)
    {
        string[] t = spec.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        PixelCompareTests.Canvas? canvas = null;
        PdfRgbaImage? scanned = null;
        for (int i = 0; i < t.Length;)
        {
            switch (t[i])
            {
                case "text":
                    canvas = PixelCompareTests.Text(scale: double.Parse(t[i + 2], System.Globalization.CultureInfo.InvariantCulture), seed: int.Parse(t[i + 1]));
                    i += 3;
                    break;
                case "fill":
                    canvas!.Fill(int.Parse(t[i + 1]), int.Parse(t[i + 2]), int.Parse(t[i + 3]), int.Parse(t[i + 4]), byte.Parse(t[i + 5]));
                    i += 6;
                    break;
                default:
                    scanned = PixelCompareTests.Scan(canvas!, double.Parse(t[i + 1], System.Globalization.CultureInfo.InvariantCulture), int.Parse(t[i + 2]), int.Parse(t[i + 3]), int.Parse(t[i + 4]));
                    i += 5;
                    break;
            }
        }
        return scanned ?? canvas!.ToImage();
    }
}
