using System.IO.Compression;
using System.Text;

namespace LazyPDF.Core;

// From Lazy Scan's ExportZip.cs, with deflate in place of stored entries.

internal sealed record ExportZipEntry(string Name, byte[] Data);

/// <summary>
/// A minimal zip writer for the Office packages: entries deflated when that is smaller, dated
/// 1980-01-01, in the order given, with a CRC-32 per entry. No zip64; a package past 65534 entries or 1 GB is refused with a <see cref="PdfReadException"/>.
/// </summary>
internal static class ExportZip
{
    // 1980-01-01, the earliest date a zip holds: the same bytes on every save.
    private const ushort DosDate = (0 << 9) | (1 << 5) | 1;

    // A MemoryStream stops at 2 GB, so the package is refused well before.
    private const long MaxPackage = 1L << 30;

    private static readonly uint[] Table = MakeTable();

    // 0xFFFF in the end record is the zip64 marker, so that count is already too many.
    private const int MaxEntries = ushort.MaxValue - 1;

    private static PdfReadException TooLarge() => new(PdfReadProblem.Unsupported, ExportText.TooLarge);

    /// <summary>Refuses a package of more entries than the end record can count, for a writer to ask before it builds them.</summary>
    public static void CheckCount(long entries)
    {
        if (entries > MaxEntries) throw TooLarge();
    }

    /// <summary>The CRC-32 of zip and PNG (polynomial 0xEDB88320, reflected); pass the previous value to continue.</summary>
    public static uint Crc32(ReadOnlySpan<byte> data, uint crc = 0)
    {
        crc ^= 0xFFFFFFFF;
        foreach (byte b in data) crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFF;
    }

    public static byte[] Make(IReadOnlyList<ExportZipEntry> entries)
    {
        CheckCount(entries.Count);
        if (entries.Sum(e => (long)e.Data.Length) > MaxPackage) throw TooLarge();
        using var output = new MemoryStream();
        using var central = new MemoryStream();
        foreach (var entry in entries)
        {
            byte[] name = Encoding.UTF8.GetBytes(entry.Name);
            ushort flags = (ushort)(entry.Name.Any(c => c > 0x7F) ? 0x0800 : 0);
            uint crc = Crc32(entry.Data);
            byte[] stored = entry.Data;
            ushort method = 0;
            if (entry.Data.Length > 0 && Deflate(entry.Data) is { } packed && packed.Length < entry.Data.Length)
            {
                stored = packed;
                method = 8;
            }
            long offset = output.Position;
            if (offset > uint.MaxValue || stored.LongLength > uint.MaxValue) throw TooLarge();
            ushort version = method == 8 ? (ushort)20 : (ushort)10;

            WriteUInt32(output, 0x04034B50);
            WriteUInt16(output, version);
            WriteUInt16(output, flags);
            WriteUInt16(output, method);
            WriteUInt16(output, 0);
            WriteUInt16(output, DosDate);
            WriteUInt32(output, crc);
            WriteUInt32(output, (uint)stored.Length);
            WriteUInt32(output, (uint)entry.Data.Length);
            WriteUInt16(output, (ushort)name.Length);
            WriteUInt16(output, 0);
            output.Write(name);
            output.Write(stored);

            WriteUInt32(central, 0x02014B50);
            WriteUInt16(central, 20);
            WriteUInt16(central, version);
            WriteUInt16(central, flags);
            WriteUInt16(central, method);
            WriteUInt16(central, 0);
            WriteUInt16(central, DosDate);
            WriteUInt32(central, crc);
            WriteUInt32(central, (uint)stored.Length);
            WriteUInt32(central, (uint)entry.Data.Length);
            WriteUInt16(central, (ushort)name.Length);
            WriteUInt16(central, 0);
            WriteUInt16(central, 0);
            WriteUInt16(central, 0);
            WriteUInt16(central, 0);
            WriteUInt32(central, 0);
            WriteUInt32(central, (uint)offset);
            central.Write(name);
        }

        long centralOffset = output.Position;
        central.Position = 0;
        central.CopyTo(output);
        long centralSize = output.Position - centralOffset;
        if (output.Position > uint.MaxValue) throw TooLarge();

        WriteUInt32(output, 0x06054B50);
        WriteUInt16(output, 0);
        WriteUInt16(output, 0);
        WriteUInt16(output, (ushort)entries.Count);
        WriteUInt16(output, (ushort)entries.Count);
        WriteUInt32(output, (uint)centralSize);
        WriteUInt32(output, (uint)centralOffset);
        WriteUInt16(output, 0);
        return output.ToArray();
    }

    private static byte[] Deflate(byte[] data)
    {
        using var packed = new MemoryStream();
        using (var z = new DeflateStream(packed, CompressionLevel.Optimal, leaveOpen: true)) z.Write(data);
        return packed.ToArray();
    }

    private static uint[] MakeTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }

    private static void WriteUInt16(Stream stream, ushort value)
    {
        stream.WriteByte((byte)value);
        stream.WriteByte((byte)(value >> 8));
    }

    private static void WriteUInt32(Stream stream, uint value)
    {
        stream.WriteByte((byte)value);
        stream.WriteByte((byte)(value >> 8));
        stream.WriteByte((byte)(value >> 16));
        stream.WriteByte((byte)(value >> 24));
    }
}
