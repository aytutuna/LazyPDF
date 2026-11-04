using System.Buffers.Binary;

namespace LazyPDF.Core;

// Empties the outlines of the glyphs a font is not used for. Glyph numbers, the cmap and the
// metrics stay as they were, so no code in a PDF has to change; that is why this is not the
// renumbering subsetter in Fonts/.
internal static class TrueTypeTrim
{
    private static readonly string[] Kept = ["OS/2", "cmap", "cvt ", "fpgm", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name", "post", "prep"];
    private const int MaxComponents = 256;

    public static byte[]? Trim(byte[] font, IReadOnlySet<int> glyphs)
    {
        if (font.Length < 12 || BinaryPrimitives.ReadUInt32BigEndian(font) is not (0x00010000 or 0x74727565)) return null;
        int count = BinaryPrimitives.ReadUInt16BigEndian(font.AsSpan(4));
        if (12 + 16 * count > font.Length) return null;
        var tables = new SortedDictionary<string, byte[]>(StringComparer.Ordinal);
        for (int i = 0; i < count; i++)
        {
            var entry = font.AsSpan(12 + 16 * i, 16);
            string tag = System.Text.Encoding.Latin1.GetString(entry[..4]);
            long offset = BinaryPrimitives.ReadUInt32BigEndian(entry[8..]), length = BinaryPrimitives.ReadUInt32BigEndian(entry[12..]);
            if (offset + length > font.Length) return null;
            if (Kept.Contains(tag)) tables[tag] = font.AsSpan((int)offset, (int)length).ToArray();
        }
        if (!tables.TryGetValue("head", out var head) || !tables.TryGetValue("maxp", out var maxp) || !tables.TryGetValue("loca", out var loca)
            || !tables.TryGetValue("glyf", out var glyf) || head.Length < 54 || maxp.Length < 6) return null;
        int numGlyphs = BinaryPrimitives.ReadUInt16BigEndian(maxp.AsSpan(4));
        bool longLoca = BinaryPrimitives.ReadInt16BigEndian(head.AsSpan(50)) != 0;
        if (loca.Length < (numGlyphs + 1) * (longLoca ? 4 : 2)) return null;

        long Start(int glyph) => longLoca ? BinaryPrimitives.ReadUInt32BigEndian(loca.AsSpan(4 * glyph)) : 2L * BinaryPrimitives.ReadUInt16BigEndian(loca.AsSpan(2 * glyph));
        (int Start, int Length) Range(int glyph)
        {
            long from = Start(glyph), to = Start(glyph + 1);
            return from < 0 || to <= from || to > glyf.Length ? (0, 0) : ((int)from, (int)(to - from));
        }

        var keep = new HashSet<int> { 0 };
        var queue = new Queue<int>([0]);
        foreach (int g in glyphs.Where(g => g > 0 && g < numGlyphs))
        {
            if (keep.Add(g)) queue.Enqueue(g);
        }
        while (queue.Count > 0)
        {
            var (start, length) = Range(queue.Dequeue());
            if (length < 10 || BinaryPrimitives.ReadInt16BigEndian(glyf.AsSpan(start)) >= 0) continue;
            int p = start + 10, end = start + length;
            for (int parts = 0; parts < MaxComponents && p + 4 <= end; parts++)
            {
                int flags = BinaryPrimitives.ReadUInt16BigEndian(glyf.AsSpan(p)), part = BinaryPrimitives.ReadUInt16BigEndian(glyf.AsSpan(p + 2));
                if (part < numGlyphs && keep.Add(part)) queue.Enqueue(part);
                p += 4 + ((flags & 1) != 0 ? 4 : 2) + ((flags & 8) != 0 ? 2 : (flags & 0x40) != 0 ? 4 : (flags & 0x80) != 0 ? 8 : 0);
                if ((flags & 0x20) == 0) break;
            }
        }

        var newGlyf = new MemoryStream();
        var newLoca = new byte[4 * (numGlyphs + 1)];
        for (int g = 0; g < numGlyphs; g++)
        {
            BinaryPrimitives.WriteUInt32BigEndian(newLoca.AsSpan(4 * g), (uint)newGlyf.Length);
            if (!keep.Contains(g)) continue;
            var (start, length) = Range(g);
            newGlyf.Write(glyf, start, length);
            while (newGlyf.Length % 4 != 0) newGlyf.WriteByte(0);
        }
        BinaryPrimitives.WriteUInt32BigEndian(newLoca.AsSpan(4 * numGlyphs), (uint)newGlyf.Length);
        tables["glyf"] = newGlyf.ToArray();
        tables["loca"] = newLoca;
        head = (byte[])head.Clone();
        BinaryPrimitives.WriteInt16BigEndian(head.AsSpan(50), 1);
        tables["head"] = head;
        return Assemble(BinaryPrimitives.ReadUInt32BigEndian(font), tables);
    }

    private static byte[] Assemble(uint version, SortedDictionary<string, byte[]> tables)
    {
        int n = tables.Count;
        int entrySelector = (int)Math.Log2(n);
        var output = new MemoryStream();
        var header = new byte[12 + 16 * n];
        BinaryPrimitives.WriteUInt32BigEndian(header, version);
        BinaryPrimitives.WriteUInt16BigEndian(header.AsSpan(4), (ushort)n);
        BinaryPrimitives.WriteUInt16BigEndian(header.AsSpan(6), (ushort)(16 << entrySelector));
        BinaryPrimitives.WriteUInt16BigEndian(header.AsSpan(8), (ushort)entrySelector);
        BinaryPrimitives.WriteUInt16BigEndian(header.AsSpan(10), (ushort)(16 * n - (16 << entrySelector)));
        output.Write(header);
        int position = header.Length, adjustAt = -1, entry = 0;
        foreach (var (tag, data) in tables)
        {
            if (tag == "head") adjustAt = position + 8;
            var record = header.AsSpan(12 + 16 * entry++, 16);
            System.Text.Encoding.Latin1.GetBytes(tag, record[..4]);
            BinaryPrimitives.WriteUInt32BigEndian(record[4..], tag == "head" ? Checksum(data.AsSpan(), skip: 8) : Checksum(data));
            BinaryPrimitives.WriteUInt32BigEndian(record[8..], (uint)position);
            BinaryPrimitives.WriteUInt32BigEndian(record[12..], (uint)data.Length);
            output.Write(data);
            int pad = (4 - data.Length % 4) % 4;
            output.Write(new byte[pad]);
            position += data.Length + pad;
        }
        var file = output.ToArray();
        header.CopyTo(file, 0);
        BinaryPrimitives.WriteUInt32BigEndian(file.AsSpan(adjustAt), 0);
        BinaryPrimitives.WriteUInt32BigEndian(file.AsSpan(adjustAt), 0xB1B0AFBA - Checksum(file));
        return file;
    }

    // With skip set, the word at that offset counts as zero (the head table's checksum adjustment).
    private static uint Checksum(ReadOnlySpan<byte> data, int skip = -1)
    {
        uint sum = 0;
        for (int i = 0; i < data.Length; i += 4)
        {
            uint word = 0;
            for (int k = 0; k < 4; k++) word = word << 8 | (i + k < data.Length ? data[i + k] : (byte)0);
            if (i != skip) sum += word;
        }
        return sum;
    }
}
