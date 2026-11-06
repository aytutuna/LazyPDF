using System.IO.Compression;

namespace LazyPDF.Core;

/// <summary>
/// Reads a zip or gzip file the way the check of an attached file needs: strictly, so that a file counts as read only when
/// every byte of it is accounted for. ZipArchive and GZipStream read what they find at the places the file points to, and
/// other tools find a directory, a member or a prefix that they do not. What this cannot account for for is null, and the
/// caller counts the file as not checked.
/// </summary>
internal static class RedactionArchive
{
    private const int MaxName = 1 << 16;

    /// <summary>Whether the data holds the signature of a local header or of an end record, wherever it is.</summary>
    public static bool HasZipSignature(byte[] d)
    {
        var span = d.AsSpan();
        return span.IndexOf("PK\u0003\u0004"u8) >= 0 || span.IndexOf("PK\u0005\u0006"u8) >= 0;
    }

    private static long U16(byte[] d, long at) => at >= 0 && at + 2 <= d.Length ? d[at] | d[at + 1] << 8 : -1;

    private static long U32(byte[] d, long at) =>
        at >= 0 && at + 4 <= d.Length ? d[at] | (long)d[at + 1] << 8 | (long)d[at + 2] << 16 | (long)d[at + 3] << 24 : -1;

    private sealed record Item(long Local, long Flags, long Method, long Crc, long Packed, long Size, byte[] Name);

    /// <summary>
    /// The entries of a zip file, inflated, when the file is one and nothing in it is left unexplained: the end record closes the
    /// file, the directory sits just before it and holds the entries it counts, the local entries follow one another from the first
    /// byte to the directory, each with the header and the sizes its directory entry has, and each inflates to exactly its size and
    /// its CRC-32 and uses exactly its packed bytes. <paramref name="over"/> is set when they hold more than <paramref name="budget"/>.
    /// </summary>
    public static List<byte[]>? Unzip(byte[] d, long budget, out bool over)
    {
        over = false;
        long end = -1;
        for (long i = d.Length - 22; i >= 0 && i >= d.Length - 22 - 0xFFFF; i--)
        {
            if (d[i] == 0x50 && d[i + 1] == 0x4B && d[i + 2] == 5 && d[i + 3] == 6 && i + 22 + U16(d, i + 20) == d.Length)
            {
                end = i;
                break;
            }
        }
        if (end < 0) return null;
        long count = U16(d, end + 10), size = U32(d, end + 12), offset = U32(d, end + 16);
        // One disk, the classic record (zip64 is not read here), and the directory closing right before the end record.
        if (U16(d, end + 4) != 0 || U16(d, end + 6) != 0 || U16(d, end + 8) != count || count == 0xFFFF || size == 0xFFFFFFFF || offset == 0xFFFFFFFF) return null;
        if (end >= 20 && U32(d, end - 20) == 0x07064B50) return null;
        if (offset + size != end) return null;

        var items = new List<Item>();
        long at = offset;
        for (long n = 0; n < count; n++)
        {
            long name = U16(d, at + 28), extra = U16(d, at + 30), comment = U16(d, at + 32);
            if (U32(d, at) != 0x02014B50 || name < 0 || extra < 0 || comment < 0 || U16(d, at + 34) != 0) return null;
            long next = at + 46 + name + extra + comment;
            if (next > end) return null;
            long flags = U16(d, at + 8), method = U16(d, at + 10), packed = U32(d, at + 20), plain = U32(d, at + 24);
            // Encrypted, or sizes and offsets that only a zip64 record can hold.
            if ((flags & 0x41) != 0 || packed == 0xFFFFFFFF || plain == 0xFFFFFFFF || U32(d, at + 42) == 0xFFFFFFFF) return null;
            items.Add(new Item(U32(d, at + 42), flags, method, U32(d, at + 16), packed, plain, d[(int)(at + 46)..(int)(at + 46 + name)]));
            at = next;
        }
        if (at != end) return null;

        var found = new List<byte[]>();
        long cursor = 0, total = 0;
        foreach (var item in items.OrderBy(i => i.Local))
        {
            if (item.Local != cursor || U32(d, cursor) != 0x04034B50) return null;
            long name = U16(d, cursor + 26), extra = U16(d, cursor + 28);
            if (name != item.Name.Length || extra < 0 || U16(d, cursor + 6) != item.Flags || U16(d, cursor + 8) != item.Method) return null;
            long start = cursor + 30 + name + extra;
            if (start > offset || !d.AsSpan((int)(cursor + 30), (int)name).SequenceEqual(item.Name)) return null;
            long stop = start + item.Packed;
            if (stop > offset) return null;
            bool descriptor = (item.Flags & 8) != 0;
            if (!descriptor && (U32(d, cursor + 14) != item.Crc || U32(d, cursor + 18) != item.Packed || U32(d, cursor + 22) != item.Size)) return null;
            long localCrc = U32(d, cursor + 14);
            if (descriptor && localCrc != 0 && localCrc != item.Crc) return null;
            cursor = stop;
            if (descriptor)
            {
                long at2 = U32(d, cursor) == 0x08074B50 ? cursor + 4 : cursor;
                if (U32(d, at2) != item.Crc || U32(d, at2 + 4) != item.Packed || U32(d, at2 + 8) != item.Size) return null;
                cursor = at2 + 12;
            }
            if (cursor > offset) return null;
            total += item.Size;
            if (total > budget)
            {
                over = true;
                return null;
            }
            var bytes = Entry(d.AsSpan((int)start, (int)item.Packed), item);
            if (bytes is null) return null;
            found.Add(bytes);
        }
        return cursor == offset ? found : null;
    }

    private static byte[]? Entry(ReadOnlySpan<byte> packed, Item item)
    {
        byte[] bytes;
        if (item.Method == 0)
        {
            if (item.Packed != item.Size) return null;
            bytes = packed.ToArray();
        }
        else if (item.Method == 8)
        {
            if (item.Packed == 0 && item.Size == 0) return [];
            var source = new OneByte(packed.ToArray());
            bytes = new byte[item.Size];
            try
            {
                using var inflated = new DeflateStream(source, CompressionMode.Decompress);
                int got = 0;
                for (int n; got < bytes.Length && (n = inflated.Read(bytes, got, bytes.Length - got)) > 0;) got += n;
                // The stream ends where the size says, having used the packed bytes and no others.
                if (got != bytes.Length || inflated.Read(new byte[1]) != 0 || source.Used != item.Packed) return null;
            }
            catch (InvalidDataException)
            {
                return null;
            }
        }
        else
        {
            return null;
        }
        return Crc32(bytes) == item.Crc ? bytes : null;
    }

    /// <summary>
    /// The members of a gzip file, inflated and joined as GZipStream joins them, when each has a header zlib accepts (no reserved
    /// flag, the header checksum right when there is one), a deflate stream that ends, and a trailer that is its own. Zero bytes after
    /// the last member are padding; anything else after one is not a member, and the file is not read.
    /// </summary>
    public static byte[]? Gunzip(byte[] d, long budget, out bool over)
    {
        over = false;
        var all = new MemoryStream();
        long at = 0;
        do
        {
            if (at + 18 > d.Length || d[at] != 0x1F || d[at + 1] != 0x8B || d[at + 2] != 8 || (d[at + 3] & 0xE0) != 0) return null;
            int flags = d[at + 3];
            long p = at + 10;
            if ((flags & 4) != 0)
            {
                long extra = U16(d, p);
                if (extra < 0) return null;
                p += 2 + extra;
            }
            foreach (int bit in new[] { 8, 16 })
            {
                if ((flags & bit) == 0) continue;
                while (p < d.Length && d[p] != 0) p++;
                p++;
            }
            if ((flags & 2) != 0)
            {
                if (p + 2 > d.Length || U16(d, p) != (Crc32(d.AsSpan((int)at, (int)(p - at))) & 0xFFFF)) return null;
                p += 2;
            }
            if (p >= d.Length) return null;
            var source = new OneByte(d, (int)p);
            var plain = new MemoryStream();
            try
            {
                using var inflated = new DeflateStream(source, CompressionMode.Decompress);
                var chunk = new byte[1 << 16];
                for (int n; (n = inflated.Read(chunk)) > 0;)
                {
                    plain.Write(chunk, 0, n);
                    if (all.Length + plain.Length > budget)
                    {
                        over = true;
                        return null;
                    }
                }
            }
            catch (InvalidDataException)
            {
                return null;
            }
            long trailer = p + source.Used;
            var bytes = plain.ToArray();
            if (trailer + 8 > d.Length || U32(d, trailer) != Crc32(bytes) || U32(d, trailer + 4) != (bytes.LongLength & 0xFFFFFFFF)) return null;
            all.Write(bytes);
            at = trailer + 8;
            if (at < d.Length && d.AsSpan((int)at).IndexOfAnyExcept((byte)0) < 0) at = d.Length;
        } while (at < d.Length);
        return all.ToArray();
    }

    private static long Crc32(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (byte b in data)
        {
            crc ^= b;
            for (int k = 0; k < 8; k++) crc = (crc & 1) != 0 ? 0xEDB88320 ^ crc >> 1 : crc >> 1;
        }
        return ~crc;
    }

    /// <summary>
    /// Gives bytes one at a time, so that what a DeflateStream has used of them is known to the byte: it asks for more only when
    /// it needs more, and not at all once its last block is done.
    /// </summary>
    private sealed class OneByte : Stream
    {
        private readonly byte[] data;
        private readonly int first;
        private int _at;

        public OneByte(byte[] data, int first = 0)
        {
            (this.data, this.first, _at) = (data, first, first);
        }

        public long Used => _at - first;

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (count == 0 || _at >= data.Length) return 0;
            buffer[offset] = data[_at++];
            return 1;
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
