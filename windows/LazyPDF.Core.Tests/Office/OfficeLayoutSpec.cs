using System.Globalization;
using System.Text;
using LazyPDF.Core;
using LazyPDF.Core.Office;

namespace LazyPDF.Core.Tests;

// Reads layout-input.txt, the cases of Tests/Fixtures/golden/office-layout, into documents.
// Mirrored by Tests/LazyPDFKitTests/Office, which reads the same file.
internal static class OfficeLayoutSpec
{
    /// <summary>The bundled fonts, found by family and style as the apps do.</summary>
    public sealed class BundledFonts : IFontSource
    {
        private readonly Dictionary<string, FontFile?> _files = [];

        public FontFile? Find(string family, FontStyles style)
        {
            string suffix = style switch
            {
                FontStyles.Bold => "Bold",
                FontStyles.Italic => "Italic",
                FontStyles.Bold | FontStyles.Italic => "BoldItalic",
                _ => "Regular",
            };
            string file = family.Replace(" ", "") + "-" + suffix + ".ttf";
            if (_files.TryGetValue(file, out var known)) return known;
            string path = Path.Combine(AppContext.BaseDirectory, "Fonts", file);
            return _files[file] = File.Exists(path) ? new FontFile(File.ReadAllBytes(path)) : null;
        }
    }

    public static IFontSource Fonts() => new OfficeFontSource(null, new BundledFonts());

    public static List<(string Name, LayoutDocument Document)> Read(string input)
    {
        var cases = new List<(string, LayoutDocument)>();
        LayoutDocument? document = null;
        LayoutSection? section = null;
        string band = "body";
        (Dictionary<string, string> Keys, List<LayoutRun> Runs)? paragraph = null;

        void Flush()
        {
            if (paragraph is not { } p || section is null) return;
            var made = new LayoutParagraph
            {
                Runs = p.Runs,
                Align = p.Keys.GetValueOrDefault("align") switch { "center" => LayoutAlign.Center, "right" => LayoutAlign.Right, "justify" => LayoutAlign.Justify, _ => LayoutAlign.Left },
                Left = Number(p.Keys, "left"),
                Right = Number(p.Keys, "right"),
                FirstLine = Number(p.Keys, "first"),
                Before = Number(p.Keys, "before"),
                After = Number(p.Keys, "after"),
                LineSpacing = p.Keys.ContainsKey("line") ? Number(p.Keys, "line") : 1,
                Rule = p.Keys.GetValueOrDefault("rule") switch { "exact" => LineRule.Exact, "atleast" => LineRule.AtLeast, _ => LineRule.Multiple },
                KeepWithNext = p.Keys.ContainsKey("keep"),
                PageBreakBefore = p.Keys.ContainsKey("break"),
                WidowControl = !p.Keys.ContainsKey("nowidow"),
            };
            if (band == "header") section.Header.Add(made);
            else if (band == "footer") section.Footer.Add(made);
            else section.Blocks.Add(made);
            paragraph = null;
        }

        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string command = line.Split(' ')[0];
            string rest = line.Length > command.Length ? line[(command.Length + 1)..] : "";
            switch (command)
            {
                case "case":
                    Flush();
                    document = new LayoutDocument();
                    cases.Add((rest, document));
                    section = null;
                    break;
                case "section":
                    Flush();
                    section = new LayoutSection();
                    document!.Sections.Add(section);
                    band = "body";
                    break;
                case "page":
                    double[] n = [.. rest.Split(' ').Select(s => double.Parse(s, CultureInfo.InvariantCulture))];
                    section!.Page = new LayoutGeometry
                    {
                        Width = n[0], Height = n[1], Top = n[2], Right = n[3], Bottom = n[4], Left = n[5],
                        HeaderDistance = n.Length > 6 ? n[6] : 36, FooterDistance = n.Length > 7 ? n[7] : 36,
                    };
                    break;
                case "band":
                    Flush();
                    band = rest;
                    break;
                case "p":
                    Flush();
                    paragraph = (Keys(rest), []);
                    break;
                case "r":
                    int bar = rest.IndexOf('|');
                    var keys = Keys(rest[..bar]);
                    string text = rest[(bar + 1)..];
                    if (text.StartsWith(' ')) text = text[1..];
                    paragraph!.Value.Runs.Add(new LayoutRun
                    {
                        Text = Unescape(text),
                        Family = keys.GetValueOrDefault("font")?.Replace('_', ' ') ?? OfficeFontSource.DefaultFamily,
                        Size = keys.ContainsKey("size") ? Number(keys, "size") : 11,
                        Bold = keys.ContainsKey("b"),
                        Italic = keys.ContainsKey("i"),
                        Underline = keys.ContainsKey("u"),
                        Strike = keys.ContainsKey("s"),
                        Color = keys.ContainsKey("color") ? Convert.ToInt32(keys["color"], 16) : 0,
                        Highlight = keys.ContainsKey("hl") ? Convert.ToInt32(keys["hl"], 16) : null,
                        Shift = Number(keys, "shift"),
                        Field = keys.GetValueOrDefault("field") switch { "page" => LayoutField.PageNumber, "pages" => LayoutField.PageCount, _ => LayoutField.None },
                    });
                    break;
                case "pagebreak":
                    Flush();
                    section!.Blocks.Add(new LayoutPageBreak());
                    break;
                case "skip":
                    string[] w = rest.Split(' ');
                    document!.Skipped.Add(new SkippedFeature(w[0], int.Parse(w[1], CultureInfo.InvariantCulture)));
                    break;
                default:
                    throw new InvalidDataException(line);
            }
        }
        Flush();
        return cases;
    }

    private static Dictionary<string, string> Keys(string text)
    {
        var keys = new Dictionary<string, string>();
        foreach (string word in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = word.IndexOf('=');
            keys[eq < 0 ? word : word[..eq]] = eq < 0 ? "" : word[(eq + 1)..];
        }
        return keys;
    }

    private static double Number(Dictionary<string, string> keys, string key) =>
        keys.TryGetValue(key, out string? value) ? double.Parse(value, CultureInfo.InvariantCulture) : 0;

    public static string Unescape(string text)
    {
        var result = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] != '\\')
            {
                result.Append(text[i]);
                continue;
            }
            char c = text[++i];
            switch (c)
            {
                case 'n': result.Append('\n'); break;
                case 't': result.Append('\t'); break;
                case 'f': result.Append('\f'); break;
                case 'u':
                    result.Append((char)Convert.ToInt32(text.Substring(i + 1, 4), 16));
                    i += 4;
                    break;
                default: result.Append(c); break;
            }
        }
        return result.ToString();
    }

    public static string Escape(string text)
    {
        var result = new StringBuilder();
        foreach (char c in text)
        {
            switch (c)
            {
                case '\\': result.Append(@"\\"); break;
                case '\n': result.Append(@"\n"); break;
                case '\t': result.Append(@"\t"); break;
                case '\f': result.Append(@"\f"); break;
                default:
                    if (c < 0x20) result.Append(@"\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else result.Append(c);
                    break;
            }
        }
        return result.ToString();
    }
}
