using System.Text;

namespace LazyPDF.Core;

/// <summary>What a zip package may hold. The ratio applies to entries from <see cref="RatioFloor"/> bytes up, since tiny parts pack oddly.</summary>
internal sealed record ZipLimits(int MaxEntries = 20_000, long MaxTotal = 256L << 20, long MaxEntry = 128L << 20, int MaxRatio = 200)
{
    public const long RatioFloor = 1 << 20;

    public static readonly ZipLimits Default = new();
}

/// <summary>
/// Reads the entries of a zip file by name, from the central directory (so data descriptors need no care), stored or deflated,
/// zip64 sizes and offsets included. Limits are checked from the sizes the directory declares before anything is inflated, and an
/// entry is inflated no further than its declared size, so a bomb is refused whatever it claims. Part names are case-insensitive,
/// as in OPC packages. Not a validator: bytes outside the entries are ignored.
/// </summary>
internal sealed class ZipReader
{
    private sealed record Entry(long Local, long Packed, long Size, uint Crc, int Method);

    private readonly byte[] _data;
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> _names = [];

    private ZipReader(byte[] data) => _data = data;

    /// <summary>The names of the files in the package (not folders), in directory order, with / as separator.</summary>
    public IReadOnlyList<string> Names => _names;

    public bool Contains(string name) => _entries.ContainsKey(name);

    public static ZipReader Open(byte[] data, ZipLimits? limits = null)
    {
        limits ??= ZipLimits.Default;
        var zip = new ZipReader(data);
        zip.ReadDirectory(limits);
        return zip;
    }

    public byte[] Read(string name)
    {
        if (!_entries.TryGetValue(name, out var e)) throw PdfReadException.Damaged($"The package has no part {name}.");
        var d = _data;
        if (U32(d, e.Local) != 0x04034B50) throw PdfReadException.Damaged($"The entry {name} has no header.");
        long start = e.Local + 30 + U16(d, e.Local + 26) + U16(d, e.Local + 28);
        if (e.Packed > d.Length - start) throw PdfReadException.Damaged($"The entry {name} is cut short.");
        var packed = d.AsSpan((int)start, (int)e.Packed);
        byte[] bytes;
        if (e.Method == 0)
        {
            if (e.Packed != e.Size) throw PdfReadException.Damaged($"The entry {name} has two sizes.");
            bytes = packed.ToArray();
        }
        else
        {
            bytes = e.Packed == 0 ? [] : PdfFilters.InflateRaw(packed.ToArray(), e.Size);
        }
        if (bytes.Length != e.Size || ExportZip.Crc32(bytes) != e.Crc) throw PdfReadException.Damaged($"The entry {name} does not match its checksum.");
        return bytes;
    }

    private static long U16(byte[] d, long at) => at >= 0 && at <= d.Length - 2 ? d[at] | d[at + 1] << 8 : throw Cut();

    private static long U32(byte[] d, long at) =>
        at >= 0 && at <= d.Length - 4 ?d[at] | (long)d[at + 1] << 8 | (long)d[at + 2] << 16 | (long)d[at + 3] << 24 : throw Cut();

    private static long U64(byte[] d, long at)
    {
        long low = U32(d, at), high = U32(d, at + 4);
        if (high >= 1L << 31) throw Cut();
        return low | high << 32;
    }

    private static PdfReadException Cut() => PdfReadException.Damaged("The zip file is cut short or its directory is damaged.");

    private static PdfReadException Over(string what) => new(PdfReadProblem.Unsupported, $"The zip file is refused: {what}.");

    private void ReadDirectory(ZipLimits limits)
    {
        var d = _data;
        long end = -1;
        for (long i = d.Length - 22; i >= 0 && i >= d.Length - 22 - 0xFFFF; i--)
        {
            if (d[i] == 0x50 && d[i + 1] == 0x4B && d[i + 2] == 5 && d[i + 3] == 6)
            {
                end = i;
                break;
            }
        }
        if (end < 0) throw PdfReadException.Damaged("There is no zip directory.");
        if (U16(d, end + 4) != 0 || U16(d, end + 6) != 0) throw new PdfReadException(PdfReadProblem.Unsupported, "A zip file in several parts is not supported.");
        long count = U16(d, end + 10), size = U32(d, end + 12), offset = U32(d, end + 16);
        if ((count == 0xFFFF || size == 0xFFFFFFFF || offset == 0xFFFFFFFF) && end >= 20 && U32(d, end - 20) == 0x07064B50)
        {
            long record = U64(d, end - 12);
            if (U32(d, record) != 0x06064B50) throw Cut();
            (count, size, offset) = (U64(d, record + 32), U64(d, record + 40), U64(d, record + 48));
        }
        if (count > limits.MaxEntries) throw Over("too many entries");
        if (offset > d.Length || size > d.Length - offset) throw Cut();

        long at = offset, total = 0;
        for (long n = 0; n < count; n++)
        {
            if (U32(d, at) != 0x02014B50) throw Cut();
            long flags = U16(d, at + 8), method = U16(d, at + 10);
            long packed = U32(d, at + 20), plain = U32(d, at + 24), local = U32(d, at + 42);
            long nameLength = U16(d, at + 28), extraLength = U16(d, at + 30), commentLength = U16(d, at + 32);
            long nameAt = at + 46, extraAt = nameAt + nameLength, crc = U32(d, at + 16);
            at = extraAt + extraLength + commentLength;
            if (at > offset + size) throw Cut();
            if (plain == 0xFFFFFFFF || packed == 0xFFFFFFFF || local == 0xFFFFFFFF)
                (plain, packed, local) = Zip64(d, extraAt, extraLength, plain, packed, local);
            if ((flags & 0x41) != 0) throw new PdfReadException(PdfReadProblem.Unsupported, "An encrypted zip file is not supported.");

            string name = Encoding.UTF8.GetString(d, (int)nameAt, (int)nameLength).Replace('\\', '/');
            if (name.StartsWith('/') || name.Split('/').Contains("..")) throw PdfReadException.Damaged($"The entry name {name} leaves the package.");
            if (name.EndsWith('/')) continue;
            if (method is not (0 or 8)) throw new PdfReadException(PdfReadProblem.Unsupported, $"The entry {name} uses a compression method this reader lacks.");
            if (plain > limits.MaxEntry) throw Over("an entry is too large");
            if (plain >= ZipLimits.RatioFloor && plain > packed * limits.MaxRatio) throw Over("an entry is packed too tightly");
            total += plain;
            if (total > limits.MaxTotal) throw Over("the entries are too large together");
            if (!_entries.TryAdd(name, new Entry(local, packed, plain, (uint)crc, (int)method)))
                throw PdfReadException.Damaged($"The entry {name} is in the package twice.");
            _names.Add(name);
        }
    }

    private static (long Plain, long Packed, long Local) Zip64(byte[] d, long at, long length, long plain, long packed, long local)
    {
        long stop = at + length;
        while (at + 4 <= stop)
        {
            long id = U16(d, at), field = U16(d, at + 2);
            at += 4;
            if (id == 1)
            {
                if (plain == 0xFFFFFFFF) { plain = U64(d, at); at += 8; }
                if (packed == 0xFFFFFFFF) { packed = U64(d, at); at += 8; }
                if (local == 0xFFFFFFFF) local = U64(d, at);
                return (plain, packed, local);
            }
            at += field;
        }
        throw Cut();
    }
}
