using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

// Prior art: Lazy Scan's GlyphlessCodes.ToUnicodeCMap, which writes the same preamble.

/// <summary>Writes the body of a ToUnicode CMap stream (ISO 32000-1 9.10.3).</summary>
public static class ToUnicodeCMap
{
    // A bfchar or bfrange section holds at most 100 entries (Adobe Technical Note 5014).
    const int SectionSize = 100;

    /// <summary>
    /// The stream data for a font whose character codes are <paramref name="codeBytes"/> bytes (1 to 4)
    /// long. Codes in a row that map to characters in a row become one bfrange. A code given twice
    /// keeps its last text; empty text is left out. Throws ArgumentOutOfRangeException for a code that
    /// does not fit the length.
    /// </summary>
    public static byte[] Write(IEnumerable<KeyValuePair<int, string>> map, int codeBytes = 2)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(codeBytes, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(codeBytes, 4);
        ulong limit = 1UL << (8 * codeBytes);
        var sorted = new SortedDictionary<uint, string>();
        foreach (var (code, text) in map)
        {
            if ((ulong)(uint)code >= limit)
                throw new ArgumentOutOfRangeException(nameof(map), $"Code {code} does not fit {codeBytes} bytes.");
            if (!string.IsNullOrEmpty(text))
                sorted[(uint)code] = text;
        }

        var chars = new List<KeyValuePair<uint, string>>();
        var ranges = new List<(uint Lo, uint Hi, string Text)>();
        foreach (var pair in sorted)
        {
            if (ranges.Count > 0 && Continues(ranges[^1], pair.Key, pair.Value))
            {
                var last = ranges[^1];
                ranges[^1] = (last.Lo, pair.Key, last.Text);
            }
            else
                ranges.Add((pair.Key, pair.Key, pair.Value));
        }

        string width = "X" + (2 * codeBytes).ToString(CultureInfo.InvariantCulture);
        string top = new('F', 2 * codeBytes);
        var sb = new StringBuilder();
        sb.Append("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n");
        sb.Append("/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def\n");
        sb.Append("/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n");
        sb.Append("1 begincodespacerange\n<").Append(new string('0', 2 * codeBytes)).Append("> <").Append(top).Append(">\nendcodespacerange\n");

        var singles = ranges.Where(r => r.Lo == r.Hi).ToList();
        var spans = ranges.Where(r => r.Lo != r.Hi).ToList();
        for (int start = 0; start < spans.Count; start += SectionSize)
        {
            int count = Math.Min(SectionSize, spans.Count - start);
            sb.Append(count.ToString(CultureInfo.InvariantCulture)).Append(" beginbfrange\n");
            for (int i = start; i < start + count; i++)
            {
                var (lo, hi, text) = spans[i];
                sb.Append('<').Append(lo.ToString(width, CultureInfo.InvariantCulture)).Append("> <")
                  .Append(hi.ToString(width, CultureInfo.InvariantCulture)).Append("> <").Append(Utf16Hex(text)).Append(">\n");
            }
            sb.Append("endbfrange\n");
        }
        for (int start = 0; start < singles.Count; start += SectionSize)
        {
            int count = Math.Min(SectionSize, singles.Count - start);
            sb.Append(count.ToString(CultureInfo.InvariantCulture)).Append(" beginbfchar\n");
            for (int i = start; i < start + count; i++)
                sb.Append('<').Append(singles[i].Lo.ToString(width, CultureInfo.InvariantCulture)).Append("> <")
                  .Append(Utf16Hex(singles[i].Text)).Append(">\n");
            sb.Append("endbfchar\n");
        }
        sb.Append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        return Encoding.ASCII.GetBytes(sb.ToString());
    }

    // The next code extends the range when its text is the range's last text plus one in the final UTF-16 unit.
    // Neither the code's nor the unit's low byte may wrap inside the range: readers differ on what a carry means.
    static bool Continues((uint Lo, uint Hi, string Text) range, uint code, string text)
    {
        if (code != range.Hi + 1 || (code ^ range.Lo) > 0xFF || text.Length != range.Text.Length)
            return false;
        int span = (int)(code - range.Lo);
        char first = range.Text[^1];
        if (!text.AsSpan(0, text.Length - 1).SequenceEqual(range.Text.AsSpan(0, text.Length - 1)))
            return false;
        return text[^1] == (char)(first + span) && (first & 0xFF) + span <= 0xFF;
    }

    static string Utf16Hex(string text)
    {
        var sb = new StringBuilder(text.Length * 4);
        foreach (char c in text)
            sb.Append(((int)c).ToString("X4", CultureInfo.InvariantCulture));
        return sb.ToString();
    }
}
