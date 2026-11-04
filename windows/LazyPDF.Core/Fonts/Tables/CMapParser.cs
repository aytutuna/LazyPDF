using System.Text;

namespace LazyPDF.Core;

// Reads the PostScript subset CMaps are written in (ISO 32000-1 9.10.3, Adobe Technical Note 5014) into a
// CMap, and the packed form of the predefined ones (see CMapData).
internal static class CMapParser
{
    public static void Run(byte[] data, CMap map)
    {
        var lx = new CMapLexer(data);
        ReadOnlySpan<byte> lastName = default;
        for (var kind = lx.Next(); kind != CMapLexer.Kind.End && !map.Full; kind = lx.Next())
        {
            if (kind == CMapLexer.Kind.Name)
            {
                lastName = lx.Text;
                if (lastName.SequenceEqual("WMode"u8) && lx.Next() == CMapLexer.Kind.Number)
                    map.IsVertical = lx.Number == 1;
                else if (lastName.SequenceEqual("CMapName"u8) && lx.Next() == CMapLexer.Kind.Name)
                    map.Name = Encoding.Latin1.GetString(lx.Text);
            }
            else if (kind == CMapLexer.Kind.Word && lx.Text.SequenceEqual("usecmap"u8))
            {
                var parent = CMap.Predefined(Encoding.Latin1.GetString(lastName));
                if (!parent.IsFallback)
                    map.SetParent(parent);
            }
            else if (kind == CMapLexer.Kind.Word)
                Section(ref lx, map);
        }
    }

    static void Section(ref CMapLexer lx, CMap map)
    {
        var word = lx.Text;
        if (word.SequenceEqual("begincodespacerange"u8)) CodeSpaces(ref lx, map);
        else if (word.SequenceEqual("begincidrange"u8)) CidRanges(ref lx, map.Cids, map);
        else if (word.SequenceEqual("begincidchar"u8)) CidChars(ref lx, map.Cids, map);
        else if (word.SequenceEqual("beginnotdefrange"u8)) CidRanges(ref lx, map.Notdefs, map);
        else if (word.SequenceEqual("beginnotdefchar"u8)) CidChars(ref lx, map.Notdefs, map);
        else if (word.SequenceEqual("beginbfrange"u8)) BfRanges(ref lx, map);
        else if (word.SequenceEqual("beginbfchar"u8)) BfChars(ref lx, map);
    }

    static void CodeSpaces(ref CMapLexer lx, CMap map)
    {
        while (lx.Next() == CMapLexer.Kind.Hex)
        {
            if (!lx.Code(out uint lo, out int n) || lx.Next() != CMapLexer.Kind.Hex || !lx.Code(out uint hi, out int m))
                return;
            if (n == m && map.SpaceList.Count < 100)
                map.SpaceList.Add(new CMap.Codespace(n, lo, hi));
        }
    }

    static void CidRanges(ref CMapLexer lx, CodeRanges<int> into, CMap map)
    {
        while (lx.Next() == CMapLexer.Kind.Hex && !map.Full)
        {
            if (!lx.Code(out uint lo, out int n) || lx.Next() != CMapLexer.Kind.Hex || !lx.Code(out uint hi, out int m)
                || lx.Next() != CMapLexer.Kind.Number)
                return;
            if (n == m && lo <= hi && lx.Number is >= 0 and <= int.MaxValue)
                into.Add(n, lo, hi, (int)lx.Number);
        }
    }

    static void CidChars(ref CMapLexer lx, CodeRanges<int> into, CMap map)
    {
        while (lx.Next() == CMapLexer.Kind.Hex && !map.Full)
        {
            if (!lx.Code(out uint code, out int n) || lx.Next() != CMapLexer.Kind.Number)
                return;
            if (lx.Number is >= 0 and <= int.MaxValue)
                into.Add(n, code, code, (int)lx.Number);
        }
    }

    static void BfChars(ref CMapLexer lx, CMap map)
    {
        while (lx.Next() == CMapLexer.Kind.Hex && !map.Full)
        {
            if (!lx.Code(out uint code, out int n))
                return;
            var kind = lx.Next();
            string? text;
            if (kind == CMapLexer.Kind.Hex)
                text = lx.Utf16();
            else if (kind == CMapLexer.Kind.Name)
                text = GlyphList.UnicodeOf(Encoding.Latin1.GetString(lx.Text));
            else
                return;
            if (!string.IsNullOrEmpty(text))
                map.Texts.Add(n, code, code, text);
        }
    }

    static void BfRanges(ref CMapLexer lx, CMap map)
    {
        while (lx.Next() == CMapLexer.Kind.Hex && !map.Full)
        {
            if (!lx.Code(out uint lo, out int n) || lx.Next() != CMapLexer.Kind.Hex || !lx.Code(out uint hi, out int m))
                return;
            var kind = lx.Next();
            if (kind == CMapLexer.Kind.Hex)
            {
                string text = lx.Utf16();
                if (n == m && lo <= hi && text.Length > 0)
                    map.Texts.Add(n, lo, hi, text);
            }
            else if (kind == CMapLexer.Kind.ArrayOpen)
            {
                for (uint code = lo; lx.Next() == CMapLexer.Kind.Hex; code++)
                {
                    string text = lx.Utf16();
                    if (n == m && code <= hi && text.Length > 0 && !map.Full)
                        map.Texts.Add(n, code, code, text);
                }
            }
            else
                return;
        }
    }

    // The packed layout, written by the script that made CMapData: varints, zigzag for the id deltas.
    public static void ReadPacked(byte[] b, CMap map)
    {
        int at = 0;
        map.IsVertical = Varint(b, ref at) == 1;
        int nameLength = (int)Varint(b, ref at);
        if (nameLength > 0)
            map.SetParent(CMap.Predefined(Encoding.ASCII.GetString(b, at, nameLength)));
        at += nameLength;

        for (long spaces = Varint(b, ref at); spaces > 0; spaces--)
        {
            int n = b[at++];
            map.SpaceList.Add(new CMap.Codespace(n, (uint)Varint(b, ref at), (uint)Varint(b, ref at)));
        }
        for (long groups = Varint(b, ref at); groups > 0; groups--)
        {
            int n = b[at++];
            uint lo = 0;
            long cid = 0;
            for (long count = Varint(b, ref at); count > 0; count--)
            {
                lo += (uint)Varint(b, ref at);
                uint span = (uint)Varint(b, ref at);
                long zigzag = Varint(b, ref at);
                cid += (zigzag >> 1) ^ -(zigzag & 1);
                map.Cids.Add(n, lo, lo + span, (int)cid);
                cid += span + 1;
            }
        }
    }

    static long Varint(byte[] b, ref int at)
    {
        long value = 0;
        for (int shift = 0; ; shift += 7)
        {
            byte x = b[at++];
            value |= (long)(x & 0x7F) << shift;
            if ((x & 0x80) == 0)
                return value;
        }
    }
}
