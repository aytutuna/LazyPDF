using System.IO.Compression;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ZipReaderTests
{
    private sealed record Part(string Name, byte[] Packed, long Size, uint Crc, int Method = 8, int Flags = 0);

    private static byte[] Raw(byte[] data)
    {
        var o = new MemoryStream();
        using (var z = new DeflateStream(o, CompressionLevel.SmallestSize, true)) z.Write(data);
        return o.ToArray();
    }

    private static Part Deflated(string name, byte[] data) => new(name, Raw(data), data.Length, ExportZip.Crc32(data));

    private static Part Deflated(string name, string text) => Deflated(name, Encoding.UTF8.GetBytes(text));

    private static Part Stored(string name, byte[] data) => new(name, data, data.Length, ExportZip.Crc32(data), 0);

    private static void W16(Stream s, long v) => s.Write(BitConverter.GetBytes((ushort)v));

    private static void W32(Stream s, long v) => s.Write(BitConverter.GetBytes((uint)v));

    private static void W64(Stream s, long v) => s.Write(BitConverter.GetBytes(v));

    /// <summary>A zip written by hand, so that descriptors, zip64 and lying sizes can be had.</summary>
    private static byte[] Build(Part[] parts, bool descriptors = false, bool zip64 = false, string comment = "")
    {
        var o = new MemoryStream();
        var dir = new MemoryStream();
        foreach (var p in parts)
        {
            byte[] name = Encoding.UTF8.GetBytes(p.Name);
            long at = o.Position;
            int flags = p.Flags | (descriptors ? 8 : 0);
            W32(o, 0x04034B50); W16(o, 20); W16(o, flags); W16(o, p.Method); W32(o, 0);
            W32(o, descriptors ? 0 : p.Crc); W32(o, descriptors ? 0 : p.Packed.Length); W32(o, descriptors ? 0 : p.Size);
            W16(o, name.Length); W16(o, 0);
            o.Write(name);
            o.Write(p.Packed);
            if (descriptors) { W32(o, 0x08074B50); W32(o, p.Crc); W32(o, p.Packed.Length); W32(o, p.Size); }

            W32(dir, 0x02014B50); W16(dir, 45); W16(dir, 20); W16(dir, flags); W16(dir, p.Method); W32(dir, 0); W32(dir, p.Crc);
            W32(dir, zip64 ? 0xFFFFFFFF : p.Packed.Length); W32(dir, zip64 ? 0xFFFFFFFF : p.Size);
            W16(dir, name.Length); W16(dir, zip64 ? 28 : 0); W16(dir, 0); W16(dir, 0); W16(dir, 0); W32(dir, 0);
            W32(dir, zip64 ? 0xFFFFFFFF : at);
            dir.Write(name);
            if (zip64) { W16(dir, 1); W16(dir, 24); W64(dir, p.Size); W64(dir, p.Packed.Length); W64(dir, at); }
        }
        long offset = o.Position;
        dir.WriteTo(o);
        if (zip64)
        {
            long record = o.Position;
            W32(o, 0x06064B50); W64(o, 44); W16(o, 45); W16(o, 45); W32(o, 0); W32(o, 0);
            W64(o, parts.Length); W64(o, parts.Length); W64(o, dir.Length); W64(o, offset);
            W32(o, 0x07064B50); W32(o, 0); W64(o, record); W32(o, 1);
        }
        W32(o, 0x06054B50); W16(o, 0); W16(o, 0);
        W16(o, zip64 ? 0xFFFF : parts.Length); W16(o, zip64 ? 0xFFFF : parts.Length);
        W32(o, zip64 ? 0xFFFFFFFF : dir.Length); W32(o, zip64 ? 0xFFFFFFFF : offset);
        W16(o, comment.Length);
        o.Write(Encoding.ASCII.GetBytes(comment));
        return o.ToArray();
    }

    private static PdfReadException Refused(Action act) => Assert.Throws<PdfReadException>(act);

    [Fact]
    public void ReadsWhatTheWriterMakes()
    {
        byte[] big = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("<row>çay</row>", 500)));
        var zip = ZipReader.Open(ExportZip.Make([new("[Content_Types].xml", "<Types/>"u8.ToArray()), new("xl/sheet1.xml", big), new("empty.txt", [])]));
        Assert.Equal(["[Content_Types].xml", "xl/sheet1.xml", "empty.txt"], zip.Names);
        Assert.Equal(big, zip.Read("xl/sheet1.xml"));
        Assert.Equal("<Types/>", Encoding.UTF8.GetString(zip.Read("[Content_Types].xml")));
        Assert.Empty(zip.Read("empty.txt"));
    }

    [Fact]
    public void NamesAreCaseInsensitiveAndFoldersAreNotListed()
    {
        var zip = ZipReader.Open(Build([Stored("word/", []), Deflated("Word/Document.xml", "<d/>")]));
        Assert.Equal(["Word/Document.xml"], zip.Names);
        Assert.True(zip.Contains("word/document.xml"));
        Assert.Equal("<d/>", Encoding.UTF8.GetString(zip.Read("word/document.xml")));
        Refused(() => zip.Read("word/other.xml"));
    }

    [Fact]
    public void ReadsStoredEntriesDataDescriptorsAndComments()
    {
        var parts = new[] { Stored("a.txt", "stored"u8.ToArray()), Deflated("b.txt", "deflated deflated deflated") };
        var zip = ZipReader.Open(Build(parts, descriptors: true, comment: "hello"));
        Assert.Equal("stored", Encoding.UTF8.GetString(zip.Read("a.txt")));
        Assert.Equal("deflated deflated deflated", Encoding.UTF8.GetString(zip.Read("b.txt")));
    }

    [Fact]
    public void ReadsZip64SizesAndOffsets()
    {
        var zip = ZipReader.Open(Build([Deflated("a.xml", "first"), Deflated("b.xml", "second")], zip64: true));
        Assert.Equal(["a.xml", "b.xml"], zip.Names);
        Assert.Equal("second", Encoding.UTF8.GetString(zip.Read("b.xml")));
    }

    [Fact]
    public void RefusesAFileThatIsNotAZipOrIsCutShort()
    {
        Refused(() => ZipReader.Open("not a zip at all, just text"u8.ToArray()));
        Refused(() => ZipReader.Open([]));
        byte[] good = Build([Deflated("a.xml", "<a/>")]);
        Refused(() => ZipReader.Open(good[..^5]));
        // The directory points past the file.
        byte[] bad = (byte[])good.Clone();
        BitConverter.GetBytes(good.Length).CopyTo(bad, bad.Length - 6);
        Refused(() => ZipReader.Open(bad));
    }

    [Fact]
    public void RefusesAnEntryWhoseDataIsDamaged()
    {
        byte[] good = Build([Deflated("a.xml", "<a>some text some text</a>")]);
        Assert.Equal("<a>some text some text</a>", Encoding.UTF8.GetString(ZipReader.Open(good).Read("a.xml")));
        var wrongCrc = Deflated("a.xml", "<a/>") with { Crc = 1234 };
        Refused(() => ZipReader.Open(Build([wrongCrc])).Read("a.xml"));
        var truncated = Deflated("a.xml", "<a>some text some text some text</a>");
        Refused(() => ZipReader.Open(Build([truncated with { Packed = truncated.Packed[..^3] }])).Read("a.xml"));
    }

    [Fact]
    public void RefusesSizesThatLie()
    {
        byte[] data = new byte[100_000];
        var small = Deflated("a.bin", data) with { Size = 10 };
        var inflated = Refused(() => ZipReader.Open(Build([small])).Read("a.bin"));
        Assert.Equal(PdfReadProblem.Unsupported, inflated.Problem);
        var large = Deflated("a.bin", "short") with { Size = 5000 };
        Refused(() => ZipReader.Open(Build([large])).Read("a.bin"));
        var stored = Stored("a.bin", "12345"u8.ToArray()) with { Size = 4 };
        Refused(() => ZipReader.Open(Build([stored])).Read("a.bin"));
    }

    [Fact]
    public void RefusesNamesThatLeaveThePackageAndRepeats()
    {
        Refused(() => ZipReader.Open(Build([Deflated("../evil.xml", "x")])));
        Refused(() => ZipReader.Open(Build([Deflated("a/../../evil.xml", "x")])));
        Refused(() => ZipReader.Open(Build([Deflated("a\\..\\evil.xml", "x")])));
        Refused(() => ZipReader.Open(Build([Deflated("/etc/passwd", "x")])));
        Refused(() => ZipReader.Open(Build([Deflated("a.xml", "x"), Deflated("A.XML", "y")])));
    }

    [Fact]
    public void RefusesEncryptedAndUnknownMethods()
    {
        Assert.Equal(PdfReadProblem.Unsupported, Refused(() => ZipReader.Open(Build([Deflated("a.xml", "x") with { Flags = 1 }]))).Problem);
        Assert.Equal(PdfReadProblem.Unsupported, Refused(() => ZipReader.Open(Build([Deflated("a.xml", "x") with { Method = 12 }]))).Problem);
    }

    [Fact]
    public void RefusesTooManyEntries()
    {
        var parts = Enumerable.Range(0, 50).Select(i => Deflated($"p{i}.xml", "x")).ToArray();
        byte[] zip = Build(parts);
        Assert.Equal(50, ZipReader.Open(zip, new ZipLimits(MaxEntries: 50)).Names.Count);
        Refused(() => ZipReader.Open(zip, new ZipLimits(MaxEntries: 49)));
    }

    [Fact]
    public void RefusesEntriesAndTotalsOverTheLimit()
    {
        byte[] zip = Build([Deflated("a.bin", new byte[3000]), Deflated("b.bin", new byte[3000])]);
        Assert.NotNull(ZipReader.Open(zip, new ZipLimits(MaxTotal: 6000, MaxEntry: 3000)));
        Refused(() => ZipReader.Open(zip, new ZipLimits(MaxTotal: 5999)));
        Refused(() => ZipReader.Open(zip, new ZipLimits(MaxEntry: 2999)));
    }

    [Fact]
    public void RefusesAnEntryPackedTooTightly()
    {
        // 8 MB of zeros packs about a thousand to one.
        byte[] bomb = Build([Deflated("bomb.xml", new byte[8 << 20])]);
        Assert.True(bomb.Length < 20_000);
        Assert.Contains("too tightly", Refused(() => ZipReader.Open(bomb)).Message);
        Assert.Equal(8 << 20, ZipReader.Open(bomb, new ZipLimits(MaxRatio: 5000)).Read("bomb.xml").Length);
        // Text that packs ordinarily is fine at any size.
        byte[] text = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Range(0, 200_000).Select(i => $"<c r=\"A{i}\" v=\"{i * 7919 % 10007}\"/>")));
        Assert.Equal(text.Length, ZipReader.Open(Build([Deflated("s.xml", text)])).Read("s.xml").Length);
    }

    [Fact]
    public void ManyEntriesCannotAddUpPastTheTotal()
    {
        byte[] data = new byte[1 << 20];
        var parts = Enumerable.Range(0, 400).Select(i => Deflated($"e{i}", data)).ToArray();
        byte[] many = Build(parts);
        Refused(() => ZipReader.Open(many, new ZipLimits(MaxTotal: 64L << 20, MaxRatio: 5000)));
        Assert.Equal(400, ZipReader.Open(many, new ZipLimits(MaxTotal: 400L << 20, MaxRatio: 5000)).Names.Count);
    }

    [Fact]
    public void Zip64ValuesNearTheTopOfTheRangeAreRefusedNotThrown()
    {
        byte[] good = Build([Stored("a.xml", "<a/>"u8.ToArray())], zip64: true);
        int record = good.Length - 22 - 20 - 56;
        int directory = (int)BitConverter.ToInt64(good, record + 48);
        int extra = directory + 46 + "a.xml".Length + 4;
        byte[] Patched(int at, long value)
        {
            byte[] copy = (byte[])good.Clone();
            BitConverter.GetBytes(value).CopyTo(copy, at);
            return copy;
        }

        Assert.Equal("<a/>", Encoding.UTF8.GetString(ZipReader.Open(good).Read("a.xml")));
        Refused(() => ZipReader.Open(Patched(good.Length - 22 - 12, 0x7FFFFFFFFFFFFFFE)));
        Refused(() => ZipReader.Open(Patched(record + 48, long.MaxValue)));
        Refused(() => ZipReader.Open(Patched(record + 40, long.MaxValue - 1)));
        Refused(() => ZipReader.Open(Patched(extra + 16, long.MaxValue - 1)).Read("a.xml"));
        Refused(() => ZipReader.Open(Patched(extra + 8, long.MaxValue - 10)).Read("a.xml"));
    }

    [Fact]
    public void DeclaringAHugeSizeDoesNotAllocate()
    {
        var huge = Deflated("a.bin", "tiny") with { Size = int.MaxValue };
        byte[] zip = Build([huge]);
        Refused(() => ZipReader.Open(zip));
        var open = ZipReader.Open(zip, new ZipLimits(MaxTotal: long.MaxValue, MaxEntry: long.MaxValue, MaxRatio: int.MaxValue));
        Refused(() => open.Read("a.bin"));
    }
}
