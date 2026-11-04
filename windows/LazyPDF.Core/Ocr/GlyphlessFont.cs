using System.Globalization;
using System.Text;

namespace LazyPDF.Core;

// From Lazy Scan's GlyphlessFont.cs.

/// <summary>
/// The font of the invisible text layer: a TrueType program whose only glyph draws nothing and is
/// half an em wide, embedded as an Identity-H composite font in which every code shows that
/// glyph. A character of the Basic Multilingual Plane is its own UTF-16 code unit; one beyond it
/// gets a code in the surrogate range, which never stands for a character alone
/// (<see cref="GlyphlessCodes"/>). The ToUnicode map gives the text back, so any script can be
/// written, selected and searched without a font installed anywhere. Built from code, the same
/// bytes on every run.
/// </summary>
internal static class GlyphlessFont
{
    /// <summary>The font's name, in the PDF (/BaseFont, /FontName) and in its name table.</summary>
    public const string FontName = "GlyphLessFont";

    /// <summary>Units per em of the font program.</summary>
    public const int UnitsPerEm = 1000;

    /// <summary>The advance of every glyph, in 1/1000 em: the PDF's /DW and the program's hmtx agree.</summary>
    public const int GlyphWidth = 500;

    /// <summary>Character codes: 0 to this (two bytes).</summary>
    public const int CodeCount = 0x10000;

    private static readonly Lazy<byte[]> LazyProgram = new(Build);
    private static readonly Lazy<byte[]> LazyCidToGidMap = new(BuildCidToGidMap);

    /// <summary>The TrueType program (/FontFile2), built once. Do not change the array.</summary>
    public static byte[] Program => LazyProgram.Value;

    /// <summary>
    /// The /CIDToGIDMap stream's data, zlib-compressed (/Filter /FlateDecode): every code to
    /// glyph 1, so no code ever shows the .notdef glyph. Built once. Do not change the array.
    /// </summary>
    public static byte[] CidToGidMap => LazyCidToGidMap.Value;

    /// <summary>
    /// A TrueType font with two glyphs, both empty: .notdef and glyph 1, each 500 units wide on a
    /// 1000-unit em, ascent 1000 and descent 0 (so a line's text fills its box from the
    /// baseline up). Tables: OS/2, cmap (U+0020 to glyph 1), glyf, head, hhea, hmtx, loca, maxp,
    /// name and post, with their checksums and the head's checksum adjustment.
    /// </summary>
    public static byte[] Build()
    {
        var tables = new SortedDictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["OS/2"] = Os2Table(),
            ["cmap"] = CmapTable(),
            ["glyf"] = new byte[4], // both glyphs are empty (loca gives them no bytes); kept non-empty for strict readers
            ["head"] = HeadTable(),
            ["hhea"] = HheaTable(),
            ["hmtx"] = HmtxTable(),
            ["loca"] = LocaTable(),
            ["maxp"] = MaxpTable(),
            ["name"] = NameTable(),
            ["post"] = PostTable(),
        };

        int numTables = tables.Count;
        int searchPower = 1, entrySelector = 0;
        while (searchPower * 2 <= numTables) { searchPower *= 2; entrySelector++; }
        var font = new BigEndianWriter();
        font.U32(0x00010000);
        font.U16(numTables);
        font.U16(searchPower * 16);
        font.U16(entrySelector);
        font.U16(numTables * 16 - searchPower * 16);

        int offset = 12 + numTables * 16;
        var layout = new List<(byte[] Data, int Offset)>();
        int headOffset = 0;
        foreach (var (tag, data) in tables)
        {
            font.Ascii(tag);
            font.U32(Checksum(data));
            font.U32((uint)offset);
            font.U32((uint)data.Length);
            if (tag == "head") headOffset = offset;
            layout.Add((data, offset));
            offset += Padded(data.Length);
        }
        foreach (var (data, _) in layout)
        {
            font.Bytes(data);
            font.Bytes(new byte[Padded(data.Length) - data.Length]);
        }
        byte[] bytes = font.ToArray();
        // head.checkSumAdjustment (bytes 8-11 of the table) makes the whole file sum to 0xB1B0AFBA.
        uint adjustment = unchecked(0xB1B0AFBAu - Checksum(bytes));
        bytes[headOffset + 8] = (byte)(adjustment >> 24);
        bytes[headOffset + 9] = (byte)(adjustment >> 16);
        bytes[headOffset + 10] = (byte)(adjustment >> 8);
        bytes[headOffset + 11] = (byte)adjustment;
        return bytes;
    }

    private static int Padded(int length) => (length + 3) & ~3;

    /// <summary>The TrueType table checksum: the sum of its big-endian 32-bit words, zero-padded.</summary>
    internal static uint Checksum(ReadOnlySpan<byte> data)
    {
        uint sum = 0;
        for (int i = 0; i < data.Length; i += 4)
        {
            uint word = 0;
            for (int j = 0; j < 4; j++) word = (word << 8) | (i + j < data.Length ? data[i + j] : 0u);
            sum = unchecked(sum + word);
        }
        return sum;
    }

    private static byte[] Os2Table()
    {
        var t = new BigEndianWriter();
        t.U16(4);                 // version
        t.I16(GlyphWidth);        // xAvgCharWidth
        t.U16(400);               // usWeightClass: regular
        t.U16(5);                 // usWidthClass: medium
        t.U16(0);                 // fsType: installable, no embedding restrictions
        t.I16(650); t.I16(600); t.I16(0); t.I16(75);   // subscript x size, y size, x offset, y offset
        t.I16(650); t.I16(600); t.I16(0); t.I16(350);  // superscript x size, y size, x offset, y offset
        t.I16(50); t.I16(250);    // strikeout size, position
        t.I16(0);                 // sFamilyClass
        t.Bytes(new byte[10]);    // panose: any
        t.U32(0); t.U32(0); t.U32(0); t.U32(0); // ulUnicodeRange1-4
        t.Ascii("NONE");          // achVendID
        t.U16(0x0040);            // fsSelection: regular
        t.U16(0x0020);            // usFirstCharIndex
        t.U16(0x0020);            // usLastCharIndex
        t.I16(UnitsPerEm); t.I16(0); t.I16(0); // typo ascender, descender, line gap
        t.U16(UnitsPerEm); t.U16(0);           // win ascent, descent
        t.U32(1); t.U32(0);       // ulCodePageRange1-2: Latin 1
        t.I16(500); t.I16(UnitsPerEm);         // sxHeight, sCapHeight
        t.U16(0); t.U16(0x0020); t.U16(1);     // usDefaultChar, usBreakChar, usMaxContext
        return t.ToArray();
    }

    private static byte[] CmapTable()
    {
        // One Windows Unicode (3, 1) subtable, format 4: U+0020 to glyph 1, then the required
        // 0xFFFF segment. A PDF reaches the glyph through the CIDToGIDMap, never through this.
        var t = new BigEndianWriter();
        t.U16(0);   // version
        t.U16(1);   // one encoding record
        t.U16(3); t.U16(1); t.U32(12);
        const int segCount = 2;
        t.U16(4);                       // format
        t.U16(16 + segCount * 8);       // length
        t.U16(0);                       // language
        t.U16(segCount * 2);            // segCountX2
        t.U16(2 * 2);                   // searchRange: 2 × 2^floor(log2(segCount))
        t.U16(1);                       // entrySelector
        t.U16(0);                       // rangeShift
        t.U16(0x0020); t.U16(0xFFFF);   // endCode
        t.U16(0);                       // reservedPad
        t.U16(0x0020); t.U16(0xFFFF);   // startCode
        t.I16(1 - 0x0020); t.I16(1);    // idDelta
        t.U16(0); t.U16(0);             // idRangeOffset
        return t.ToArray();
    }

    private static byte[] HeadTable()
    {
        var t = new BigEndianWriter();
        t.U32(0x00010000);        // version 1.0
        t.U32(0x00010000);        // fontRevision 1.0
        t.U32(0);                 // checkSumAdjustment: set once the whole font is laid out
        t.U32(0x5F0F3CF5);        // magicNumber
        t.U16(0x000B);            // flags: baseline at y = 0, left sidebearing at x = 0, integer scaling
        t.U16(UnitsPerEm);
        t.U32(0); t.U32(0);       // created: fixed, so the bytes never change
        t.U32(0); t.U32(0);       // modified
        t.I16(0); t.I16(0); t.I16(GlyphWidth); t.I16(UnitsPerEm); // xMin, yMin, xMax, yMax
        t.U16(0);                 // macStyle
        t.U16(8);                 // lowestRecPPEM
        t.I16(2);                 // fontDirectionHint
        t.I16(0);                 // indexToLocFormat: short offsets
        t.I16(0);                 // glyphDataFormat
        return t.ToArray();
    }

    private static byte[] HheaTable()
    {
        var t = new BigEndianWriter();
        t.U32(0x00010000);
        t.I16(UnitsPerEm);        // ascender
        t.I16(0);                 // descender
        t.I16(0);                 // lineGap
        t.U16(GlyphWidth);        // advanceWidthMax
        t.I16(0); t.I16(0);       // minLeftSideBearing, minRightSideBearing
        t.I16(0);                 // xMaxExtent
        t.I16(1); t.I16(0); t.I16(0); // caretSlopeRise, caretSlopeRun, caretOffset
        t.I16(0); t.I16(0); t.I16(0); t.I16(0); // reserved
        t.I16(0);                 // metricDataFormat
        t.U16(2);                 // numberOfHMetrics
        return t.ToArray();
    }

    private static byte[] HmtxTable()
    {
        var t = new BigEndianWriter();
        for (int glyph = 0; glyph < 2; glyph++) { t.U16(GlyphWidth); t.I16(0); }
        return t.ToArray();
    }

    private static byte[] LocaTable()
    {
        var t = new BigEndianWriter();
        for (int i = 0; i < 3; i++) t.U16(0); // short offsets (bytes / 2): both glyphs empty
        return t.ToArray();
    }

    private static byte[] MaxpTable()
    {
        var t = new BigEndianWriter();
        t.U32(0x00010000);        // version 1.0 (TrueType outlines)
        t.U16(2);                 // numGlyphs
        t.U16(0); t.U16(0);       // maxPoints, maxContours
        t.U16(0); t.U16(0);       // maxCompositePoints, maxCompositeContours
        t.U16(2);                 // maxZones
        t.U16(0); t.U16(0); t.U16(0); t.U16(0); // twilight points, storage, function defs, instruction defs
        t.U16(0); t.U16(0);       // maxStackElements, maxSizeOfInstructions
        t.U16(0); t.U16(0);       // maxComponentElements, maxComponentDepth
        return t.ToArray();
    }

    private static byte[] NameTable()
    {
        (int Id, string Text)[] names = [(1, FontName), (2, "Regular"), (4, FontName), (6, FontName)];
        var strings = new BigEndianWriter();
        var records = new BigEndianWriter();
        foreach (var (id, text) in names)
        {
            byte[] utf16 = Encoding.BigEndianUnicode.GetBytes(text);
            records.U16(3); records.U16(1); records.U16(0x0409); records.U16(id);
            records.U16(utf16.Length);
            records.U16(strings.Length);
            strings.Bytes(utf16);
        }
        var t = new BigEndianWriter();
        t.U16(0);                         // format
        t.U16(names.Length);
        t.U16(6 + names.Length * 12);     // string storage offset
        t.Bytes(records.ToArray());
        t.Bytes(strings.ToArray());
        return t.ToArray();
    }

    private static byte[] PostTable()
    {
        var t = new BigEndianWriter();
        t.U32(0x00030000);        // format 3: no glyph names
        t.U32(0);                 // italicAngle
        t.I16(-100); t.I16(50);   // underlinePosition, underlineThickness
        t.U32(1);                 // isFixedPitch
        t.U32(0); t.U32(0); t.U32(0); t.U32(0); // memory hints
        return t.ToArray();
    }

    /// <summary>The map's uncompressed data: two bytes per code, each the glyph 0x0001.</summary>
    internal static byte[] CidToGidMapData()
    {
        var data = new byte[CodeCount * 2];
        for (int i = 1; i < data.Length; i += 2) data[i] = 1;
        return data;
    }

    /// <summary>
    /// The map zlib-compressed by hand: one fixed-Huffman deflate block holding the literals 00 01,
    /// then back-references of 258 bytes at distance 2 (and one of 6) for the rest, the end of
    /// block, and the Adler-32 of the data. About 830 bytes for 128 KiB, the same on every
    /// platform, with no compression library involved.
    /// </summary>
    private static byte[] BuildCidToGidMap()
    {
        var bits = new DeflateBits();
        bits.Bits(1, 1);              // BFINAL
        bits.Bits(1, 2);              // BTYPE 01: fixed Huffman codes
        bits.Literal(0x00);
        bits.Literal(0x01);
        int remaining = CodeCount * 2 - 2;     // 131070 = 508 × 258 + 6
        for (int i = 0; i < remaining / 258; i++) bits.Match(258, distance: 2);
        if (remaining % 258 > 0) bits.Match(remaining % 258, distance: 2);
        bits.EndOfBlock();

        var output = new List<byte> { 0x78, 0x01 }; // zlib: deflate, 32 KiB window, no dictionary
        output.AddRange(bits.ToArray());
        uint adler = Adler32(CidToGidMapData());
        output.AddRange([(byte)(adler >> 24), (byte)(adler >> 16), (byte)(adler >> 8), (byte)adler]);
        return [.. output];
    }

    internal static uint Adler32(ReadOnlySpan<byte> data)
    {
        const uint mod = 65521;
        uint a = 1, b = 0;
        foreach (byte value in data)
        {
            a = (a + value) % mod;
            b = (b + a) % mod;
        }
        return (b << 16) | a;
    }

    /// <summary>Deflate's bit order: fields least significant bit first, Huffman codes most significant bit first.</summary>
    private sealed class DeflateBits
    {
        private readonly List<byte> _bytes = [];
        private int _current, _count;

        public void Bits(int value, int count)
        {
            for (int i = 0; i < count; i++)
            {
                _current |= ((value >> i) & 1) << _count;
                if (++_count == 8) { _bytes.Add((byte)_current); _current = 0; _count = 0; }
            }
        }

        private void Code(int code, int length)
        {
            for (int i = length - 1; i >= 0; i--) Bits((code >> i) & 1, 1);
        }

        /// <summary>Literals 0-143 are the 8-bit codes 0x30 + value.</summary>
        public void Literal(int value) => Code(0x30 + value, 8);

        public void EndOfBlock() => Code(0, 7); // symbol 256: 7-bit code 0

        /// <summary>A length of 3-10 or 258 (symbols 257-264 and 285; no extra bits) at a distance of 1-4.</summary>
        public void Match(int length, int distance)
        {
            if (length == 258) Code(0xC0 + (285 - 280), 8);           // symbols 280-287: 8-bit codes 0xC0 +
            else if (length is >= 3 and <= 10) Code(length - 3 + 1, 7); // symbols 257-264: 7-bit codes 1-8
            else throw new ArgumentOutOfRangeException(nameof(length));
            if (distance is < 1 or > 4) throw new ArgumentOutOfRangeException(nameof(distance));
            Code(distance - 1, 5);                                    // distance codes 0-3: no extra bits
        }

        public byte[] ToArray()
        {
            var bytes = new List<byte>(_bytes);
            if (_count > 0) bytes.Add((byte)_current);
            return [.. bytes];
        }
    }

    /// <summary>
    /// The part of every ToUnicode map that never changes: each code outside the surrogate range
    /// D800-DFFF maps to the same UTF-16 code unit, as 248 ranges of 256 codes
    /// (&lt;XX00&gt; &lt;XXFF&gt; &lt;XX00&gt;) in blocks of at most 100, as CMaps require.
    /// </summary>
    internal static readonly Lazy<string> IdentityRanges = new(() =>
    {
        var highBytes = Enumerable.Range(0, 256).Where(high => high is < 0xD8 or > 0xDF).ToList();
        var sb = new StringBuilder();
        for (int start = 0; start < highBytes.Count; start += 100)
        {
            int count = Math.Min(100, highBytes.Count - start);
            sb.Append(count.ToString(CultureInfo.InvariantCulture)).Append(" beginbfrange\n");
            foreach (int high in highBytes.Skip(start).Take(count))
            {
                string h = high.ToString("X2", CultureInfo.InvariantCulture);
                sb.Append('<').Append(h).Append("00> <").Append(h).Append("FF> <").Append(h).Append("00>\n");
            }
            sb.Append("endbfrange\n");
        }
        return sb.ToString();
    });

    private sealed class BigEndianWriter
    {
        private readonly List<byte> _bytes = [];
        public int Length => _bytes.Count;
        public void U16(int value) { _bytes.Add((byte)(value >> 8)); _bytes.Add((byte)value); }
        public void I16(int value) => U16(value & 0xFFFF);
        public void U32(uint value)
        {
            _bytes.Add((byte)(value >> 24)); _bytes.Add((byte)(value >> 16));
            _bytes.Add((byte)(value >> 8)); _bytes.Add((byte)value);
        }
        public void Ascii(string text) => _bytes.AddRange(Encoding.ASCII.GetBytes(text));
        public void Bytes(ReadOnlySpan<byte> data) { foreach (byte b in data) _bytes.Add(b); }
        public byte[] ToArray() => [.. _bytes];
    }
}

/// <summary>
/// The character codes of one font. A character beyond the BMP gets a code from D800 up in the
/// order it is first used; more than 2048 of them, and any lone surrogate, are written as U+FFFD.
/// </summary>
internal sealed class GlyphlessCodes
{
    /// <summary>The first code given to a character beyond the Basic Multilingual Plane.</summary>
    public const int FirstSupplementaryCode = 0xD800;

    /// <summary>How many such characters a document can carry: the surrogate range, D800-DFFF.</summary>
    public const int SupplementaryCapacity = 0x800;

    /// <summary>What a character without a code is written as.</summary>
    public const int ReplacementCode = 0xFFFD;

    private readonly Dictionary<int, int> _codes = [];
    private readonly List<int> _supplementary = [];

    /// <summary>The codes for these texts: every character beyond the BMP in them, in order of first use.</summary>
    public static GlyphlessCodes For(IEnumerable<string> texts)
    {
        var codes = new GlyphlessCodes();
        foreach (string text in texts)
        {
            for (int i = 0; i + 1 < text.Length; i++)
            {
                if (!char.IsSurrogatePair(text[i], text[i + 1])) continue;
                int codePoint = char.ConvertToUtf32(text[i], text[i + 1]);
                i++;
                if (codes._codes.ContainsKey(codePoint) || codes._supplementary.Count == SupplementaryCapacity) continue;
                codes._codes[codePoint] = FirstSupplementaryCode + codes._supplementary.Count;
                codes._supplementary.Add(codePoint);
            }
        }
        return codes;
    }

    /// <summary>The codes an embedded font already has, read back through its ToUnicode map.</summary>
    public static GlyphlessCodes From(PdfFont font)
    {
        var codes = new GlyphlessCodes();
        Span<byte> bytes = stackalloc byte[2];
        for (int i = 0; i < SupplementaryCapacity; i++)
        {
            int code = FirstSupplementaryCode + i;
            bytes[0] = (byte)(code >> 8);
            bytes[1] = (byte)code;
            string? text = font.ToText(bytes);
            if (string.IsNullOrEmpty(text) || text.Length != 2 || !char.IsSurrogatePair(text[0], text[1])) break;
            int codePoint = char.ConvertToUtf32(text[0], text[1]);
            codes._codes[codePoint] = code;
            codes._supplementary.Add(codePoint);
        }
        return codes;
    }

    /// <summary>True when every character of <paramref name="text"/> has a code of its own.</summary>
    public bool Covers(string text)
    {
        for (int i = 0; i < text.Length; i++)
        {
            if (i + 1 < text.Length && char.IsSurrogatePair(text[i], text[i + 1]))
            {
                if (!_codes.ContainsKey(char.ConvertToUtf32(text[i], text[i + 1]))) return false;
                i++;
            }
            else if (char.IsSurrogate(text[i]))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>The characters beyond the BMP with a code, by code: the first is D800.</summary>
    public IReadOnlyList<int> Supplementary => _supplementary;

    /// <summary>The codes of <paramref name="text"/>, one per character.</summary>
    public List<int> Codes(string text)
    {
        var codes = new List<int>(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (i + 1 < text.Length && char.IsSurrogatePair(c, text[i + 1]))
            {
                codes.Add(_codes.TryGetValue(char.ConvertToUtf32(c, text[++i]), out int code) ? code : ReplacementCode);
            }
            else
            {
                codes.Add(char.IsSurrogate(c) ? ReplacementCode : c);
            }
        }
        return codes;
    }

    /// <summary>The string operand for <paramref name="text"/>: two bytes per code.</summary>
    public byte[] Bytes(string text)
    {
        var codes = Codes(text);
        var bytes = new byte[codes.Count * 2];
        for (int i = 0; i < codes.Count; i++)
        {
            bytes[2 * i] = (byte)(codes[i] >> 8);
            bytes[2 * i + 1] = (byte)codes[i];
        }
        return bytes;
    }

    /// <summary>
    /// The ToUnicode CMap: every code outside D800-DFFF is the UTF-16 code unit it was written
    /// from (<see cref="GlyphlessFont.IdentityRanges"/>), and each code from D800 is its
    /// character's surrogate pair, in blocks of at most 100.
    /// </summary>
    public string ToUnicodeCMap()
    {
        var sb = new StringBuilder();
        sb.Append("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n");
        sb.Append("/CIDSystemInfo <</Registry (Adobe) /Ordering (UCS) /Supplement 0>> def\n");
        sb.Append("/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n");
        sb.Append("1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        sb.Append(GlyphlessFont.IdentityRanges.Value);
        for (int start = 0; start < _supplementary.Count; start += 100)
        {
            int count = Math.Min(100, _supplementary.Count - start);
            sb.Append(count.ToString(CultureInfo.InvariantCulture)).Append(" beginbfchar\n");
            for (int i = start; i < start + count; i++)
            {
                string pair = char.ConvertFromUtf32(_supplementary[i]);
                sb.Append('<').Append((FirstSupplementaryCode + i).ToString("X4", CultureInfo.InvariantCulture)).Append("> <")
                  .Append(((int)pair[0]).ToString("X4", CultureInfo.InvariantCulture))
                  .Append(((int)pair[1]).ToString("X4", CultureInfo.InvariantCulture)).Append(">\n");
            }
            sb.Append("endbfchar\n");
        }
        sb.Append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        return sb.ToString();
    }
}
