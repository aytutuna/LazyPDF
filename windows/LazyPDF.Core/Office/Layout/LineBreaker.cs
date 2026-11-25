namespace LazyPDF.Core.Office;

/// <summary>
/// Where a line may end: a subset of UAX 14 that covers spaces, hyphens, dashes, slashes, no-break characters,
/// quotes and brackets, and Chinese, Japanese text with the usual closing and opening marks kept off the line
/// edges. Hangul and everything else breaks only at spaces. No hyphenation.
/// </summary>
internal static class LineBreaker
{
    private enum Kind
    {
        Letter, Digit, Space, Tab, Newline, ZeroWidth, Glue, Hyphen, After, Dash, Slash,
        Open, Close, Quote, Currency, Ideo, IdeoOpen, IdeoClose, Object,
    }

    /// <summary>Entry i is true when a line may end before code point i. Entry 0 is never true.</summary>
    public static bool[] Opportunities(IReadOnlyList<int> text)
    {
        var result = new bool[text.Count];
        var kinds = new Kind[text.Count];
        for (int i = 0; i < text.Count; i++) kinds[i] = KindOf(text[i]);
        // Opening marks keep the word after them even across spaces, so the last solid kind is tracked.
        Kind solid = Kind.Letter;
        for (int i = 1; i < text.Count; i++)
        {
            if (kinds[i - 1] is not (Kind.Space or Kind.Tab or Kind.ZeroWidth or Kind.Newline)) solid = kinds[i - 1];
            result[i] = Allowed(text, kinds, i, solid);
        }
        return result;
    }

    private static bool Allowed(IReadOnlyList<int> text, Kind[] kinds, int i, Kind solid)
    {
        Kind before = kinds[i - 1], after = kinds[i];
        if (before == Kind.Newline) return true;
        if (after == Kind.Newline) return false;
        if (after == Kind.ZeroWidth) return false;
        if (before == Kind.ZeroWidth) return true;
        if (after is Kind.Space or Kind.Tab) return false;
        if (before == Kind.Glue || after == Kind.Glue) return false;
        if (after is Kind.Close or Kind.Slash or Kind.Hyphen or Kind.After or Kind.IdeoClose or Kind.Quote) return false;
        if (before is Kind.Space or Kind.Tab) return solid is not (Kind.Open or Kind.IdeoOpen);
        if (before is Kind.Open or Kind.IdeoOpen or Kind.Currency or Kind.Quote) return false;
        if (before == Kind.Object || after == Kind.Object) return true;
        if (before == Kind.Hyphen) return i >= 2 && kinds[i - 2] is Kind.Letter or Kind.Digit or Kind.Ideo && after != Kind.Digit;
        if (before == Kind.After) return true;
        if (before == Kind.Slash) return after != Kind.Digit;
        if (before == Kind.Dash || after == Kind.Dash) return before != after;
        return IsIdeographic(before) || IsIdeographic(after);
    }

    private static bool IsIdeographic(Kind kind) => kind is Kind.Ideo or Kind.IdeoOpen or Kind.IdeoClose;

    private static Kind KindOf(int c)
    {
        switch (c)
        {
            case ' ': case 0x1680: case 0x2000: case 0x2001: case 0x2002: case 0x2003: case 0x2004: case 0x2005:
            case 0x2006: case 0x2008: case 0x2009: case 0x200A: case 0x205F:
                return Kind.Space;
            case '\t': return Kind.Tab;
            case '\n': return Kind.Newline;
            case 0x200B: return Kind.ZeroWidth;
            case ParagraphLayout.ObjectCode: return Kind.Object;
            case 0xA0: case 0x2007: case 0x202F: case 0x2011: case 0x2060: case 0xFEFF: return Kind.Glue;
            case '-': return Kind.Hyphen;
            case 0x2010: case 0x2012: case 0x2013: return Kind.After;
            case 0x2014: return Kind.Dash;
            case '/': return Kind.Slash;
            case '(': case '[': case '{': case 0x201C: case 0x2018: case 0xAB: case 0x2039: case 0xA1: case 0xBF: return Kind.Open;
            case ')': case ']': case '}': case ',': case '.': case ':': case ';': case '!': case '?': case '%':
            case 0x201D: case 0x2019: case 0xBB: case 0x203A: case 0x2030: case 0x2026:
                return Kind.Close;
            case '"': case '\'': return Kind.Quote;
            case '$': case 0xA3: case 0xA5: case 0x20AC: return Kind.Currency;
        }
        if (c is >= '0' and <= '9') return Kind.Digit;
        if (!IsIdeograph(c)) return Kind.Letter;
        if (IdeoOpeners.Contains(c)) return Kind.IdeoOpen;
        if (IdeoClosers.Contains(c)) return Kind.IdeoClose;
        return Kind.Ideo;
    }

    private static bool IsIdeograph(int c) =>
        c is >= 0x2E80 and <= 0x303F or >= 0x3041 and <= 0x33FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF
            or >= 0xF900 and <= 0xFAFF or >= 0xFF01 and <= 0xFF60 or >= 0xFF61 and <= 0xFF9F or >= 0xFFE0 and <= 0xFFE6
            or >= 0x20000 and <= 0x3FFFF;

    private static readonly HashSet<int> IdeoOpeners =
    [
        0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014, 0x3016, 0x3018, 0x301A, 0x301D,
        0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62,
    ];

    // Closing marks, small kana, the prolonged sound mark and iteration marks cannot start a line.
    private static readonly HashSet<int> IdeoClosers =
    [
        0x3001, 0x3002, 0x3005, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0x3017, 0x3019, 0x301B, 0x301E, 0x301F,
        0x303B, 0x309B, 0x309C, 0x309D, 0x309E, 0x30FB, 0x30FC, 0x30FD, 0x30FE,
        0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
        0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3, 0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6,
        0xFF01, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF3D, 0xFF5D, 0xFF60, 0xFF63, 0xFF64, 0xFF9E, 0xFF9F,
    ];
}
