using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

/// <summary>
/// A page's text as a search sees it: white space runs and line breaks become one space, case and
/// diacritics are folded as asked, and every character of it points back at the page character it came from.
/// </summary>
internal sealed class SearchText
{
    public string Text = "";
    public int[] Map = [];

    /// <summary>For each character of <see cref="Text"/>, the offsets in its page character's own text that a hit on it takes: from the start of the letter it was made from (with the mark it is on, if it is a mark) to the end of that letter and the marks after it. A space the search made up at a line break takes none (0 to 0).</summary>
    public int[] From = [], To = [];

    public int StartOf(int index) => From[index];

    public int EndOf(int index) => To[index];

    private static bool IsMark(char c) =>
        CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;

    /// <summary>The page has a hyphen at a line end that a join would take out.</summary>
    public bool HasHyphenBreak;

    public static SearchText Build(TextPage page, TextSearchOptions options, bool dropHyphens)
    {
        var sb = new StringBuilder(page.Chars.Count + 16);
        var map = new List<int>(page.Chars.Count + 16);
        var from = new List<int>(page.Chars.Count + 16);
        var to = new List<int>(page.Chars.Count + 16);
        bool hyphenBreak = false;
        int line = -1;
        bool soft = false;

        void Space(int index, int end)
        {
            if (sb.Length == 0 || sb[^1] == ' ') return;
            sb.Append(' ');
            map.Add(index);
            from.Add(0);
            to.Add(end);
        }

        foreach (var c in page.Chars)
        {
            if (c.Line != line)
            {
                if (line >= 0 && sb.Length > 0 && sb[^1] != ' ')
                {
                    if (soft && page.Lines[c.Line].Before == TextBreak.Line)
                    {
                        hyphenBreak = true;
                    }
                    else if (page.Lines[c.Line].Before == TextBreak.Line && !c.IsSpace && JoinsAfterHyphen(sb, c))
                    {
                        hyphenBreak = true;
                        if (dropHyphens)
                        {
                            sb.Length--;
                            map.RemoveAt(map.Count - 1);
                            from.RemoveAt(from.Count - 1);
                            to.RemoveAt(to.Count - 1);
                        }
                    }
                    else
                    {
                        Space(c.Index, 0);
                    }
                }
                line = c.Line;
                soft = false;
            }
            if (c.IsSpace)
            {
                Space(c.Index, 1);
                continue;
            }
            if (c.Text == "\u00AD")
            {
                soft = true;
                continue;
            }
            soft = false;
            for (int u = 0; u < c.Text.Length; u++)
            {
                foreach (char f in Fold(c.Text.Length == 1 ? c.Text : c.Text[u].ToString(), options))
                {
                    sb.Append(f);
                    map.Add(c.Index);
                    int start = u, end = u + 1;
                    while (start > 0 && IsMark(c.Text[start])) start--;
                    while (end < c.Text.Length && IsMark(c.Text[end])) end++;
                    from.Add(start);
                    to.Add(end);
                }
            }
        }
        return new SearchText { Text = sb.ToString(), Map = [.. map], From = [.. from], To = [.. to], HasHyphenBreak = hyphenBreak };
    }

    private static bool JoinsAfterHyphen(StringBuilder sb, TextChar next) =>
        sb.Length >= 2 && sb[^1] is '-' or '\u2010' or '\u2011' && char.IsLetter(sb[^2]) && next.Text.Length > 0 && char.IsLetter(next.Text[0]);

    // Dotless i is a different letter until diacritics are folded; dotted capital I is always i.
    public static string Fold(string text, TextSearchOptions options)
    {
        if (options.FoldDiacritics) text = StripMarks(text);
        var sb = new StringBuilder(text.Length);
        foreach (char c in text)
        {
            if (options.MatchCase) sb.Append(c);
            else sb.Append(c == '\u0130' ? 'i' : char.ToLowerInvariant(c));
        }
        return sb.ToString();
    }

    public static string Collapse(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (char c in text.Trim())
        {
            if (char.IsWhiteSpace(c))
            {
                if (sb.Length > 0 && sb[^1] != ' ') sb.Append(' ');
            }
            else
            {
                sb.Append(c);
            }
        }
        return sb.ToString();
    }

    internal static string StripMarks(string text)
    {
        bool plain = true;
        foreach (char c in text)
        {
            if (c >= 0xC0 || c == '\u0131')
            {
                plain = false;
                break;
            }
        }
        if (plain) return text;
        var sb = new StringBuilder(text.Length + 2);
        foreach (char c in text)
        {
            switch (c)
            {
                case '\u0131': sb.Append('i'); continue;
                case '\u0130': sb.Append('I'); continue;
                case '\u00DF': sb.Append("ss"); continue;
                case '\u00E6': sb.Append("ae"); continue;
                case '\u00C6': sb.Append("AE"); continue;
                case '\u0153': sb.Append("oe"); continue;
                case '\u0152': sb.Append("OE"); continue;
                case '\u00F8': sb.Append('o'); continue;
                case '\u00D8': sb.Append('O'); continue;
                case '\u0142': sb.Append('l'); continue;
                case '\u0141': sb.Append('L'); continue;
                case '\u0111': sb.Append('d'); continue;
                case '\u0110': sb.Append('D'); continue;
            }
            // Hangul syllables and the like stay whole: decomposing them would change what a CJK search finds.
            if (c < 0xC0 || c >= 0x2E80)
            {
                sb.Append(c);
                continue;
            }
            foreach (char d in c.ToString().Normalize(NormalizationForm.FormD))
            {
                if (CharUnicodeInfo.GetUnicodeCategory(d) != UnicodeCategory.NonSpacingMark) sb.Append(d);
            }
        }
        return sb.ToString();
    }
}
