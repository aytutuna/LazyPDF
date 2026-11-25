using System.Globalization;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Accessibility/AccessibilityGolden.swift. One line of input is "<op> <fixture>" (the format
// is at the top of accessibility-input.txt): trees read from hand-made files, the check list, a file tagged by AutoTagger and a
// tree written after a move, and the three patterns Swift matches by hand where the C# has a Regex (list markers, page numbers
// and language tags) with the folded text of a line. A file is shown as every object with the trailer, streams decoded, so that the numbers the tagger
// gives to new objects and the sequences it writes into the content are pinned; the compressed bytes themselves are not, as
// Swift writes its own deflate.
internal static class AccessibilityGolden
{
    public static string Run(string input)
    {
        var english = Loc.Table;
        Loc.Table = new Dictionary<string, string>();
        try
        {
            var output = new StringBuilder();
            foreach (string line in input.Split('\n'))
            {
                if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
                int space = line.IndexOf(' ');
                string op = space < 0 ? line : line[..space];
                string rest = space < 0 ? "" : line[(space + 1)..];
                output.Append("> ").Append(line).Append('\n');
                foreach (string result in Op(op, rest)) output.Append("< ").Append(result).Append('\n');
            }
            return output.ToString();
        }
        finally
        {
            Loc.Table = english;
        }
    }

    private static IEnumerable<string> Op(string op, string rest)
    {
        switch (op)
        {
            case "marker": return [Marker(Text(rest))];
            case "pagenumber": return [Bool(TagText.IsPageNumber(Text(rest)))];
            case "signature": return [TagText.Signature(Text(rest)) is { } signature ? Show(signature) : "none"];
            case "langtag": return [LanguageTag(Text(rest))];
        }
        if (Fixture(rest) is not { } file) return [$"unknown fixture {rest}"];
        using var document = PdfDocument.Open(file);
        switch (op)
        {
            case "tree": return Tree(document).ToList();
            case "check": return Check(document).ToList();
            case "tag": return Tag(document).ToList();
            case "move": return Move(document).ToList();
            default: return [$"unknown op {op}"];
        }
    }

    private static string Text(string rest) => Encoding.UTF8.GetString(Golden.Unescape(rest));

    private static string Marker(string text)
    {
        string found = TagText.MarkerOf(text) is { } marker ? $"{(marker.Numbered ? "numbered" : "bullet")} {marker.Length}" : "none";
        return $"{found} lone={Bool(TagText.IsLoneMarker(text))}";
    }

    // Whether SetLanguage takes the text, which is whether the language tag pattern matches it.
    private static string LanguageTag(string text)
    {
        using var document = PdfDocument.Open(TaggedFile.Build());
        try
        {
            AccessibilityChecker.Fix(document, AccessibilityFix.SetLanguage, text);
            return "valid";
        }
        catch (ArgumentException)
        {
            return "invalid";
        }
    }

    // tagged | tagged-bad | report <pages> | rotated <pages> | page <escaped content of the only page>
    private static byte[]? Fixture(string spec)
    {
        int space = spec.IndexOf(' ');
        string kind = space < 0 ? spec : spec[..space];
        string arg = space < 0 ? "" : spec[(space + 1)..];
        switch (kind)
        {
            case "tagged": return TaggedFile.Build();
            case "tagged-bad":
                return TaggedFile.Build(o =>
                {
                    o[10] = "<</Type /StructElem /S /Weird /P 9 0 R /Pg 3 0 R /K 0>>";
                    o[11] = "<</Type /StructElem /S /H3 /P 9 0 R /Pg 3 0 R /K 1>>";
                    o[12] = "<</Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R /K 2>>";
                }, catalog: "");
            case "report": return AccessKit.Report(int.Parse(arg, CultureInfo.InvariantCulture));
            case "rotated": return AccessKit.Build(int.Parse(arg, CultureInfo.InvariantCulture), AccessKit.ReportPage, pageEntries: "/Rotate 90");
            case "page":
                string content = Encoding.Latin1.GetString(Golden.Unescape(arg));
                return AccessKit.Build(1, _ => content);
            default: return null;
        }
    }

    private static IEnumerable<string> Tree(PdfDocument document)
    {
        var tree = StructureTree.Read(document);
        foreach (string line in DumpTree(tree)) yield return line;
        yield return "order " + Show(ReadingOrder.Export(document, tree));
    }

    private static IEnumerable<string> Check(PdfDocument document)
    {
        foreach (var item in AccessibilityChecker.Check(document).Items)
        {
            string places = string.Join(",", item.Where.Select(p => $"{p.PageIndex}:{p.Element?.Number ?? -1}"));
            yield return $"{Name(item.Rule)} {Name(item.Status)} {Name(item.Fix)} [{places}] {Show(item.Name)} | {Show(item.Message)}";
        }
    }

    private static IEnumerable<string> Tag(PdfDocument document)
    {
        var result = AutoTagger.Tag(document, new AutoTagOptions("en-US"));
        string figures = string.Join(",", result.FiguresWithoutAlt.Select(f => $"{f.PageIndex}:{f.Reference.Number}"));
        yield return $"result {Bool(result.AlreadyTagged)} pages={result.Pages} skipped={result.SkippedPages} headings={result.Headings} " +
            $"paragraphs={result.Paragraphs} lists={result.Lists} tables={result.Tables} figures={result.Figures} artifacts={result.Artifacts} [{figures}]";
        foreach (string line in Dump(document)) yield return line;
        foreach (string line in Tree(document)) yield return line;
    }

    private static IEnumerable<string> Move(PdfDocument document)
    {
        if (StructureTree.Read(document) is null) AutoTagger.Tag(document);
        var tree = StructureTree.Read(document)!;
        var root = tree.Roots[0];
        tree.Move(root.Children.Last(), root, 0);
        tree.Write(document);
        foreach (string line in Dump(document)) yield return line;
        foreach (string line in DumpTree(StructureTree.Read(document))) yield return line;
    }

    private static IEnumerable<string> DumpTree(StructureTree? tree)
    {
        if (tree is null)
        {
            yield return "no tree";
            yield break;
        }
        foreach (var root in tree.Roots)
        {
            foreach (string line in DumpElement(root, 0)) yield return line;
        }
        foreach (var (key, value) in tree.RoleMap) yield return $"role {key} {value}";
        foreach (var (key, value) in tree.ClassMap) yield return $"class {key} {value}";
        foreach (var (key, value) in tree.ParentTree) yield return $"parent {key} {value}";
        yield return "truncated " + Bool(tree.IsTruncated);
    }

    private static IEnumerable<string> DumpElement(StructElement element, int depth)
    {
        string pad = new(' ', depth * 2);
        yield return $"{pad}{Show(element.Type)} page={element.PageIndex} ref={element.Reference?.Number ?? -1} title={Opt(element.Title)} alt={Opt(element.Alt)} " +
            $"lang={Opt(element.Lang)} actual={Opt(element.ActualText)} id={Opt(element.Id)}";
        foreach (var kid in element.Kids)
        {
            switch (kid)
            {
                case StructElement child:
                    foreach (string line in DumpElement(child, depth + 1)) yield return line;
                    break;
                case StructContent content:
                    yield return $"{pad}  content page={content.PageIndex} mcid={content.Mcid} stream={content.Stream?.Number ?? -1}";
                    break;
                case StructObject target:
                    yield return $"{pad}  object page={target.PageIndex} target={target.Target.Number}";
                    break;
            }
        }
    }

    private static IEnumerable<string> Dump(PdfDocument document)
    {
        yield return $"trailer {document.Trailer}";
        foreach (int number in document.ObjectNumbers)
        {
            string text = document.Get(number) switch
            {
                PdfStream s => $"stream {WithoutLength(s)} | {Show(Encoding.Latin1.GetString(document.Data(s)))}",
                null => "null",
                var value => value.ToString()!,
            };
            yield return $"{number}: {text}";
        }
    }

    // /Length is that of the compressed bytes, which differ between the two deflate writers.
    private static PdfDictionary WithoutLength(PdfStream stream)
    {
        var copy = stream.Dictionary.Copy();
        copy.Remove("Length");
        return copy;
    }

    private static string Name<T>(T value) where T : struct, Enum
    {
        string name = value.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    private static string Bool(bool value) => value ? "true" : "false";

    private static string Opt(string? text) => text is null ? "~" : Show(text);

    private static string Show(string text)
    {
        var sb = new StringBuilder();
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': sb.Append(@"\\"); break;
                case '\n': sb.Append(@"\n"); break;
                case '\r': sb.Append(@"\r"); break;
                case '\t': sb.Append(@"\t"); break;
                default:
                    if (c < 0x20 || c >= 0x7F) sb.Append(@"\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }
}
