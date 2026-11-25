namespace LazyPDF.Core;

/// <summary>The right-to-left scripts the writers lay out.</summary>
internal static class Scripts
{
    public static bool IsHebrew(int cp) => cp is >= 0x0590 and <= 0x05FF or >= 0xFB1D and <= 0xFB4F;

    public static bool IsArabic(int cp) =>
        cp is >= 0x0600 and <= 0x06FF or >= 0x0750 and <= 0x077F or >= 0x08A0 and <= 0x08FF or >= 0xFB50 and <= 0xFDFF or >= 0xFE70 and <= 0xFEFF;

    public static bool HasHebrew(IEnumerable<string> texts) => texts.Any(t => t.EnumerateRunes().Any(r => IsHebrew(r.Value)));

    public static bool HasArabic(IEnumerable<string> texts) => texts.Any(t => t.EnumerateRunes().Any(r => IsArabic(r.Value)));

    /// <summary>Whether the text needs the bidi algorithm: a right-to-left letter, or a mark or embedding that sets a direction.</summary>
    public static bool NeedsBidi(string text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (NeedsBidi(rune.Value)) return true;
        }
        return false;
    }

    public static bool NeedsBidi(int cp) =>
        IsHebrew(cp) || IsArabic(cp) || IsBidiControl(cp) || cp >= 0x0700 && BidiData.TypeOf(cp) is BidiType.R or BidiType.AL or BidiType.AN;

    /// <summary>A direction mark or embedding control: it sets a direction but has no glyph.</summary>
    public static bool IsBidiControl(int cp) => cp is 0x200E or 0x200F or 0x061C or >= 0x202A and <= 0x202E or >= 0x2066 and <= 0x2069;
}
