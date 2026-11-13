namespace LazyPDF.Core.Office;

/// <summary>Cuts text into the stretches Word and PowerPoint format apart: Hebrew and Arabic letters (complex script) and the rest.</summary>
internal static class ScriptRuns
{
    /// <summary>
    /// The stretches of <paramref name="text"/> in order. Digits, spaces and punctuation go with the letters before them,
    /// or with the first letter after them when the text starts with some.
    /// </summary>
    public static List<(string Text, bool Complex)> Split(string text)
    {
        var parts = new List<(string, bool)>();
        var runes = text.EnumerateRunes().ToList();
        int? first = runes.Select(Kind).FirstOrDefault(k => k is not null);
        if (first is null || !runes.Any(r => Scripts.IsHebrew(r.Value) || Scripts.IsArabic(r.Value)))
        {
            parts.Add((text, false));
            return parts;
        }
        int current = first.Value;
        var piece = new System.Text.StringBuilder();
        foreach (var rune in runes)
        {
            int kind = Kind(rune) ?? current;
            if (kind != current && piece.Length > 0)
            {
                parts.Add((piece.ToString(), current == 1));
                piece.Clear();
            }
            current = kind;
            piece.Append(rune.ToString());
        }
        parts.Add((piece.ToString(), current == 1));
        return parts;
    }

    /// <summary>Whether the first letter of the text is a Hebrew or Arabic one; null when there is no letter.</summary>
    public static bool? StartsComplex(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (Kind(rune) is { } kind) return kind == 1;
        }
        return null;
    }

    // 1 for a complex-script letter, 0 for a letter of another script, null for a character that has no script of its own.
    private static int? Kind(System.Text.Rune rune)
    {
        int cp = rune.Value;
        if (Scripts.IsHebrew(cp) || Scripts.IsArabic(cp)) return 1;
        bool neutral = cp < 0x41 || cp is >= 0x5B and <= 0x60 || cp is >= 0x7B and <= 0xBF || cp is >= 0x2000 and <= 0x2BFF || cp is >= 0xFE00 and <= 0xFE0F || cp == 0x200F;
        return neutral ? null : 0;
    }
}
