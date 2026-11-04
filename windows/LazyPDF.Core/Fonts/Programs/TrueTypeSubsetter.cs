using System.Text;
using static LazyPDF.Core.FontBytes;

namespace LazyPDF.Core;

public enum SubsetStatus
{
    Ok,
    Unreadable,
    /// <summary>CFF outlines, or no glyf and loca: nothing this class can cut down.</summary>
    NotTrueType,
    /// <summary>OS/2 fsType restricts embedding.</summary>
    EmbeddingForbidden,
    /// <summary>OS/2 fsType says the whole font must be embedded.</summary>
    SubsettingForbidden,
}

/// <param name="Status">Ok, or why no font was made. The other members are empty unless it is Ok.</param>
/// <param name="Data">A TrueType font for FontFile2.</param>
/// <param name="GlyphMap">Original glyph ID to the glyph ID in <paramref name="Data"/>, for every glyph kept.</param>
public sealed record SubsetResult(SubsetStatus Status, byte[] Data, IReadOnlyDictionary<int, int> GlyphMap)
{
    internal static SubsetResult Failed(SubsetStatus status) => new(status, [], new Dictionary<int, int>());
}

/// <summary>
/// Cuts a TrueType font down to some glyphs. Glyph IDs are renumbered densely in the order of the original
/// IDs (.notdef stays 0), so a PDF font made from the result uses the new ID as the character code and an
/// identity CIDToGIDMap. Composite glyphs pull in their components. Hinting is kept as is: the glyph programs
/// are copied verbatim, so cvt, fpgm and prep stay with them. The output has head, hhea, maxp, hmtx, loca, glyf,
/// post (no names), name, OS/2 and the hinting tables; no cmap, which a CIDFontType2 does not use.
/// </summary>
public static class TrueTypeSubsetter
{
    private const int MaxComponents = 512;

    public static SubsetResult Subset(byte[] font, IReadOnlyCollection<int> glyphIds, int collectionIndex = 0)
    {
        if (TrueTypeFont.TryParse(font, collectionIndex) is not { } f) return SubsetResult.Failed(SubsetStatus.Unreadable);
        if (f.IsCff || !f.HasTable("glyf") || !f.HasTable("loca")) return SubsetResult.Failed(SubsetStatus.NotTrueType);
        if (!f.EmbeddingAllowed) return SubsetResult.Failed(SubsetStatus.EmbeddingForbidden);
        if (!f.SubsettingAllowed) return SubsetResult.Failed(SubsetStatus.SubsettingForbidden);

        var kept = Close(f, glyphIds);
        var map = new Dictionary<int, int>(kept.Count);
        foreach (var old in kept) map[old] = map.Count;

        var (glyf, loca, longLoca) = BuildGlyphs(f, kept, map);
        var tables = new SortedDictionary<string, byte[]>(StringComparer.Ordinal)
        {
            ["glyf"] = glyf,
            ["loca"] = loca,
            ["hmtx"] = BuildHmtx(f, kept),
            ["head"] = BuildHead(f, longLoca),
            ["hhea"] = BuildHhea(f, kept.Count),
            ["maxp"] = BuildMaxp(f, kept.Count),
            ["post"] = BuildPost(f),
        };
        foreach (var tag in new[] { "OS/2", "cvt ", "fpgm", "prep" })
            if (f.HasTable(tag)) tables[tag] = f.Table(tag).ToArray();
        if (BuildName(f) is { } name) tables["name"] = name;

        return new SubsetResult(SubsetStatus.Ok, Assemble(tables), map);
    }

    private static SortedSet<int> Close(TrueTypeFont f, IReadOnlyCollection<int> requested)
    {
        var kept = new SortedSet<int> { 0 };
        var pending = new Stack<int>();
        foreach (var g in requested)
            if (g >= 0 && g < f.GlyphCount && kept.Add(g)) pending.Push(g);
        pending.Push(0);

        while (pending.Count > 0)
        {
            var data = f.GlyphData(pending.Pop());
            foreach (var at in ComponentOffsets(data))
            {
                var component = U16(data, at);
                if (component < f.GlyphCount && kept.Add(component)) pending.Push(component);
            }
        }
        return kept;
    }

    /// <summary>Positions of the component glyph IDs inside a composite glyph, none for a simple one.</summary>
    private static List<int> ComponentOffsets(ReadOnlySpan<byte> g)
    {
        var at = new List<int>();
        if (g.Length < 10 || I16(g, 0) >= 0) return at;
        var p = 10;
        while (p <= g.Length - 4 && at.Count < MaxComponents)
        {
            var flags = U16(g, p);
            at.Add(p + 2);
            p += 4 + ((flags & 1) != 0 ? 4 : 2);
            if ((flags & 0x8) != 0) p += 2;
            else if ((flags & 0x40) != 0) p += 4;
            else if ((flags & 0x80) != 0) p += 8;
            if ((flags & 0x20) == 0) break;
        }
        return at;
    }

    private static (byte[] Glyf, byte[] Loca, bool Long) BuildGlyphs(TrueTypeFont f, SortedSet<int> kept, Dictionary<int, int> map)
    {
        var offsets = new int[kept.Count + 1];
        using var glyf = new MemoryStream();
        var i = 0;
        foreach (var old in kept)
        {
            offsets[i++] = (int)glyf.Length;
            var data = f.GlyphData(old).ToArray();
            foreach (var at in ComponentOffsets(data))
                PutU16(data, at, map.GetValueOrDefault(U16(data, at)));
            glyf.Write(data);
            while (glyf.Length % 4 != 0) glyf.WriteByte(0);
        }
        offsets[i] = (int)glyf.Length;

        var longLoca = glyf.Length >= 0x20000;
        var loca = new byte[offsets.Length * (longLoca ? 4 : 2)];
        for (var k = 0; k < offsets.Length; k++)
        {
            if (longLoca) PutU32(loca, 4 * k, (uint)offsets[k]);
            else PutU16(loca, 2 * k, offsets[k] / 2);
        }
        return (glyf.ToArray(), loca, longLoca);
    }

    private static byte[] BuildHmtx(TrueTypeFont f, SortedSet<int> kept)
    {
        var hmtx = new byte[kept.Count * 4];
        var i = 0;
        foreach (var old in kept)
        {
            PutU16(hmtx, 4 * i, f.GetAdvance(old));
            PutU16(hmtx, 4 * i + 2, f.GetLeftSideBearing(old) & 0xFFFF);
            i++;
        }
        return hmtx;
    }

    private static byte[] BuildHead(TrueTypeFont f, bool longLoca)
    {
        var head = f.Table("head")[..54].ToArray();
        PutU32(head, 8, 0);
        PutU16(head, 50, longLoca ? 1 : 0);
        return head;
    }

    private static byte[] BuildHhea(TrueTypeFont f, int count)
    {
        var src = f.Table("hhea");
        var hhea = new byte[36];
        src[..Math.Min(src.Length, 36)].CopyTo(hhea);
        PutU16(hhea, 34, count);
        return hhea;
    }

    private static byte[] BuildMaxp(TrueTypeFont f, int count)
    {
        var src = f.Table("maxp");
        var maxp = src[..Math.Min(src.Length, 32)].ToArray();
        PutU16(maxp, 4, count);
        return maxp;
    }

    private static byte[] BuildPost(TrueTypeFont f)
    {
        var src = f.Table("post");
        var post = new byte[32];
        src[..Math.Min(src.Length, 32)].CopyTo(post);
        PutU32(post, 0, 0x00030000);
        // memory hints are meaningless without the names
        post.AsSpan(16, 16).Clear();
        return post;
    }

    private static byte[]? BuildName(TrueTypeFont f)
    {
        if (f.PostScriptName is not { } ps) return null;
        (int Id, string Text)[] records = [(1, f.FamilyName ?? ps), (4, ps), (6, ps)];
        var storage = new MemoryStream();
        var name = new byte[6 + 12 * records.Length];
        PutU16(name, 2, records.Length);
        PutU16(name, 4, name.Length);
        for (var i = 0; i < records.Length; i++)
        {
            var text = Encoding.BigEndianUnicode.GetBytes(records[i].Text);
            var r = 6 + 12 * i;
            PutU16(name, r, 3);
            PutU16(name, r + 2, 1);
            PutU16(name, r + 4, 0x409);
            PutU16(name, r + 6, records[i].Id);
            PutU16(name, r + 8, text.Length);
            PutU16(name, r + 10, (int)storage.Length);
            storage.Write(text);
        }
        return [.. name, .. storage.ToArray()];
    }

    private static byte[] Assemble(SortedDictionary<string, byte[]> tables)
    {
        var count = tables.Count;
        var entrySelector = (int)Math.Log2(count);
        var searchRange = (1 << entrySelector) * 16;

        var size = 12 + 16 * count;
        foreach (var t in tables.Values) size += (t.Length + 3) & ~3;
        var file = new byte[size];
        PutU32(file, 0, 0x00010000);
        PutU16(file, 4, count);
        PutU16(file, 6, searchRange);
        PutU16(file, 8, entrySelector);
        PutU16(file, 10, count * 16 - searchRange);

        var dir = 12;
        var offset = 12 + 16 * count;
        var headAt = 0;
        foreach (var (tag, data) in tables)
        {
            for (var k = 0; k < 4; k++) file[dir + k] = (byte)tag[k];
            PutU32(file, dir + 4, Checksum(data));
            PutU32(file, dir + 8, (uint)offset);
            PutU32(file, dir + 12, (uint)data.Length);
            data.CopyTo(file, offset);
            if (tag == "head") headAt = offset;
            offset += (data.Length + 3) & ~3;
            dir += 16;
        }
        PutU32(file, headAt + 8, 0xB1B0AFBA - Checksum(file));
        return file;
    }
}
