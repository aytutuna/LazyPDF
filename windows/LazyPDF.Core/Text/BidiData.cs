namespace LazyPDF.Core;

/// <summary>Bidi_Class values of UAX #9, in the order scripts/gen_bidi.py numbers them.</summary>
internal enum BidiType : byte
{
    L, R, AL, EN, ES, ET, AN, CS, NSM, BN, B, S, WS, ON,
    LRE, LRO, RLE, RLO, PDF, LRI, RLI, FSI, PDI,
}

internal static partial class BidiData
{
    public static BidiType TypeOf(int cp)
    {
        if ((uint)cp > 0x10FFFF) return BidiType.L;
        int lo = 0, hi = Ranges.Length - 1;
        while (lo < hi)
        {
            int mid = (lo + hi + 1) >> 1;
            if (Ranges[mid] >> 5 <= cp) lo = mid;
            else hi = mid - 1;
        }
        return (BidiType)(Ranges[lo] & 31);
    }

    /// <summary>The paired bracket of <paramref name="cp"/>, with <paramref name="opening"/> telling which end it is; 0 for any other character.</summary>
    public static int PairedBracket(int cp, out bool opening)
    {
        opening = false;
        int i = Find(Brackets, 3, cp);
        if (i < 0) return 0;
        opening = Brackets[i + 2] == 1;
        return Brackets[i + 1];
    }

    /// <summary>The character whose glyph is the mirror image of <paramref name="cp"/>'s, or <paramref name="cp"/> when there is none.</summary>
    public static int Mirror(int cp)
    {
        int i = Find(Mirrors, 2, cp);
        return i < 0 ? cp : Mirrors[i + 1];
    }

    private static int Find(int[] table, int stride, int key)
    {
        int lo = 0, hi = table.Length / stride - 1;
        while (lo <= hi)
        {
            int mid = (lo + hi) >> 1, v = table[mid * stride];
            if (v == key) return mid * stride;
            if (v < key) lo = mid + 1;
            else hi = mid - 1;
        }
        return -1;
    }
}
