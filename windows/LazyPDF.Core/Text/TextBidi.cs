namespace LazyPDF.Core;

internal enum BidiClass
{
    L,

    /// <summary>Hebrew and Arabic letters.</summary>
    R,
    EN,
    AN,
    N,
}

/// <summary>
/// Turns a line of glyphs in visual order into logical order (UAX #9 rules L1 to L2 run backwards,
/// with a simplified resolution of weak and neutral characters). Glyphs are already placed where
/// they show, so the content stream order says nothing about the logical order.
/// </summary>
internal static class TextBidi
{
    public static BidiClass ClassOf(string text)
    {
        var weak = BidiClass.N;
        foreach (char c in text)
        {
            var cls = ClassOf(c);
            if (cls is BidiClass.L or BidiClass.R) return cls;
            if (cls is BidiClass.EN or BidiClass.AN) weak = cls;
        }
        return weak;
    }

    private static BidiClass ClassOf(char c)
    {
        if (c < 0x590) return c is >= '0' and <= '9' ? BidiClass.EN : char.IsLetter(c) ? BidiClass.L : BidiClass.N;
        if (c is >= '\u0660' and <= '\u0669' or '\u066B' or '\u066C') return BidiClass.AN;
        if (c is >= '\u06F0' and <= '\u06F9') return BidiClass.EN;
        if (c is (>= '\u0590' and <= '\u08FF') or (>= '\uFB1D' and <= '\uFDFF') or (>= '\uFE70' and <= '\uFEFF'))
        {
            return char.IsLetter(c) ? BidiClass.R : BidiClass.N;
        }
        if (c is >= '\u2000' and <= '\u206F') return BidiClass.N;
        return char.IsLetter(c) ? BidiClass.L : BidiClass.N;
    }

    /// <summary>Reorders in place and sets <see cref="FlowGlyph.Level"/>; true when the line reads right to left.</summary>
    public static bool ToLogical(List<FlowGlyph> line, bool pageRtl)
    {
        int n = line.Count, strongR = 0, strongL = 0;
        var classes = new BidiClass[n];
        for (int i = 0; i < n; i++)
        {
            classes[i] = ClassOf(line[i].Text);
            if (classes[i] == BidiClass.R) strongR++;
            else if (classes[i] == BidiClass.L) strongL++;
        }
        foreach (var g in line) g.Level = 0;
        if (strongR == 0) return false;

        bool rtl = pageRtl ? strongR > 0 : strongR > strongL;
        int para = rtl ? 1 : 0, evenL = rtl ? 2 : 0;
        var levels = new int[n];
        // Nearest letter on either side, 1 for right to left; the paragraph direction when there is none.
        var before = new int[n];
        var after = new int[n];
        for (int i = 0, last = para; i < n; i++)
        {
            if (classes[i] is BidiClass.L or BidiClass.R) last = classes[i] == BidiClass.R ? 1 : 0;
            before[i] = last;
        }
        for (int i = n - 1, next = para; i >= 0; i--)
        {
            if (classes[i] is BidiClass.L or BidiClass.R) next = classes[i] == BidiClass.R ? 1 : 0;
            after[i] = next;
        }
        for (int i = 0; i < n; i++)
        {
            levels[i] = classes[i] switch
            {
                BidiClass.L => evenL,
                BidiClass.R => 1,
                BidiClass.AN => 2,
                BidiClass.EN => rtl || (before[i] == 1 && after[i] == 1) ? 2 : 0,
                _ => -1,
            };
        }
        for (int i = 0; i < n; i++)
        {
            if (levels[i] >= 0) continue;
            if (i > 0 && i + 1 < n && IsNumber(classes[i - 1]) && IsNumber(classes[i + 1]) && line[i].Text is "." or "," or ":" or "/" or "+" or "-")
            {
                levels[i] = levels[i - 1];
                continue;
            }
            if (IsTerminator(line[i].Text))
            {
                // W5: a run of terminators beside a European number belongs to the number.
                int left1 = i - 1, right1 = i + 1;
                while (left1 >= 0 && levels[left1] < 0 && IsTerminator(line[left1].Text)) left1--;
                while (right1 < n && levels[right1] < 0 && IsTerminator(line[right1].Text)) right1++;
                if (left1 >= 0 && classes[left1] == BidiClass.EN) levels[i] = levels[left1];
                else if (right1 < n && classes[right1] == BidiClass.EN) levels[i] = levels[right1];
                if (levels[i] >= 0) continue;
            }
            int a = i - 1, b = i + 1;
            while (a >= 0 && levels[a] < 0) a--;
            while (b < n && levels[b] < 0) b++;
            int left = a >= 0 ? Direction(classes[a], levels[a]) : para, right = b < n ? Direction(classes[b], levels[b]) : para;
            int direction = left == right ? left : para;
            levels[i] = direction == 1 ? 1 : evenL;
        }
        for (int i = 0; i < n; i++) line[i].Level = levels[i];

        int highest = levels.Max(), lowestOdd = levels.Where(l => (l & 1) == 1).DefaultIfEmpty(int.MaxValue).Min();
        if (lowestOdd == int.MaxValue) lowestOdd = highest + 1;
        for (int level = lowestOdd; level <= highest; level++)
        {
            for (int i = 0; i < n;)
            {
                if (line[i].Level < level)
                {
                    i++;
                    continue;
                }
                int j = i;
                while (j < n && line[j].Level >= level) j++;
                line.Reverse(i, j - i);
                i = j;
            }
        }
        foreach (var g in line)
        {
            if ((g.Level & 1) == 1) g.Text = Mirror(g.Text);
        }
        return rtl;
    }

    private static bool IsTerminator(string text) => text.Length == 1 && text[0] is '%' or '$' or '#' or '¢' or '£' or '¥' or '°' or '±' or '€';

    private static bool IsNumber(BidiClass cls) => cls is BidiClass.EN or BidiClass.AN;

    private static int Direction(BidiClass cls, int level) => cls == BidiClass.L || (cls == BidiClass.EN && level == 0) ? 0 : 1;

    private static string Mirror(string text)
    {
        if (text.Length != 1) return text;
        return text[0] switch
        {
            '(' => ")", ')' => "(", '[' => "]", ']' => "[", '{' => "}", '}' => "{", '<' => ">", '>' => "<",
            '\u00AB' => "\u00BB", '\u00BB' => "\u00AB",
            _ => text,
        };
    }
}
