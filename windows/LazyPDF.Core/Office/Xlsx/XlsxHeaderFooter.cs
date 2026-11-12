using System.Globalization;
using System.Text;

namespace LazyPDF.Core.Office;

/// <summary>A piece of header or footer text in one style.</summary>
internal sealed record HfRun(string Text, bool Bold, bool Italic);

/// <summary>What the fields of a header or footer stand for.</summary>
internal sealed record HfContext(int Page, int Pages, string Date, string Time, string File, string Sheet);

/// <summary>Reads the &amp; codes of a header or footer string into its left, centre and right sections, each a list of lines of runs.</summary>
internal static class XlsxHeaderFooter
{
    public const int MaxLines = 100;

    // Only A-Z fold, so the Swift twin matches without depending on its own case tables.
    private static string Fold(string text) => string.Create(text.Length, text, (span, s) =>
    {
        for (int i = 0; i < s.Length; i++) span[i] = s[i] is >= 'A' and <= 'Z' ? (char)(s[i] + 32) : s[i];
    });

    public static List<List<HfRun>>[] Parse(string source, HfContext context)
    {
        var sections = new List<List<HfRun>>[] { [[]], [[]], [[]] };
        int section = 1;
        bool bold = false, italic = false;
        var text = new StringBuilder();

        void Flush()
        {
            if (text.Length == 0) return;
            sections[section][^1].Add(new HfRun(text.ToString(), bold, italic));
            text.Clear();
        }

        for (int i = 0; i < source.Length; i++)
        {
            char c = source[i];
            if (c == '\r') continue;
            if (c == '\n')
            {
                Flush();
                if (sections[section].Count < MaxLines) sections[section].Add([]);
                continue;
            }
            if (c != '&' || i + 1 >= source.Length)
            {
                if (c != '&') text.Append(c);
                continue;
            }
            char code = source[++i];
            switch (code)
            {
                case '&': text.Append('&'); break;
                case 'L': Flush(); section = 0; break;
                case 'C': Flush(); section = 1; break;
                case 'R': Flush(); section = 2; break;
                case 'B': Flush(); bold = !bold; break;
                case 'I': Flush(); italic = !italic; break;
                case 'P': text.Append(context.Page.ToString(CultureInfo.InvariantCulture)); break;
                case 'N': text.Append(context.Pages.ToString(CultureInfo.InvariantCulture)); break;
                case 'D': text.Append(context.Date); break;
                case 'T': text.Append(context.Time); break;
                case 'F': text.Append(context.File); break;
                case 'A': text.Append(context.Sheet); break;
                case '"':
                    int close = source.IndexOf('"', i + 1);
                    if (close < 0) close = source.Length;
                    string font = source[(i + 1)..close];
                    i = close;
                    int comma = font.IndexOf(',');
                    if (comma < 0) break;
                    Flush();
                    string style = Fold(font[(comma + 1)..]);
                    if (style.Contains("regular", StringComparison.Ordinal) || style.Contains("normal", StringComparison.Ordinal)) bold = italic = false;
                    if (style.Contains("bold", StringComparison.Ordinal)) bold = true;
                    if (style.Contains("italic", StringComparison.Ordinal)) italic = true;
                    break;
                case 'K':
                    int run = 0;
                    while (run < 6 && i + 1 + run < source.Length && (Uri.IsHexDigit(source[i + 1 + run]) || source[i + 1 + run] is '+' or '-')) run++;
                    if (run == 6) i += 6;
                    break;
                default:
                    if (code is >= '0' and <= '9')
                    {
                        if (i + 1 < source.Length && source[i + 1] is >= '0' and <= '9') i++;
                    }
                    break;
            }
        }
        Flush();
        return sections;
    }
}
