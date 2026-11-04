using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace LazyPDF.Core;

// After Lazy Scan's PdfObjectWriter.cs (Finish, FinishUpdate, FinishUpdateStream): the cross-reference
// section that closes a file or an update, as a table (ISO 32000-1 7.5.4) or a stream (7.5.8).

/// <summary>
/// One cross-reference entry. Type 0 is free (<paramref name="Second"/> the next free number),
/// type 1 in use (the offset), type 2 stored in an object stream (the stream's number, with
/// <paramref name="Third"/> the index in it); for types 0 and 1 <paramref name="Third"/> is the generation.
/// </summary>
internal readonly record struct XrefEntry(int Number, int Type, long Second, int Third);

internal static class PdfXrefWriter
{
    /// <summary>
    /// A classic table of <paramref name="entries"/> (ascending, no type 2), a subsection to each
    /// run of consecutive numbers, then the trailer, "startxref" and "%%EOF".
    /// </summary>
    public static void WriteTable(PdfObjectWriter writer, List<XrefEntry> entries, PdfDictionary trailer)
    {
        long start = writer.Position;
        var table = new StringBuilder("xref\n");
        foreach (var (first, count) in Runs(entries))
        {
            table.Append(CultureInfo.InvariantCulture, $"{entries[first].Number} {count}\n");
            for (int i = first; i < first + count; i++)
            {
                var entry = entries[i];
                table.Append(entry.Second.ToString("D10", CultureInfo.InvariantCulture)).Append(' ')
                     .Append(entry.Third.ToString("D5", CultureInfo.InvariantCulture)).Append(entry.Type == 0 ? " f \n" : " n \n");
            }
        }
        table.Append("trailer\n");
        writer.WriteAscii(table.ToString());
        writer.WriteDirect(trailer);
        writer.WriteAscii($"\nstartxref\n{start}\n%%EOF\n");
    }

    /// <summary>
    /// A cross-reference stream, object <paramref name="number"/>, written last and listing
    /// itself. /W is [1 w 2] with w wide enough for the largest offset. <paramref name="dictionary"/>
    /// holds /Size, /Root and the rest of what a trailer holds.
    /// </summary>
    public static void WriteStream(PdfObjectWriter writer, int number, List<XrefEntry> entries, PdfDictionary dictionary, bool compress)
    {
        long start = writer.Position;
        entries.Add(new XrefEntry(number, 1, start, 0));
        int width = 1;
        foreach (var entry in entries)
        {
            while (width < 8 && entry.Second >= 1L << (width * 8)) width++;
        }
        byte[] data = new byte[entries.Count * (width + 3)];
        int at = 0;
        foreach (var entry in entries)
        {
            data[at++] = (byte)entry.Type;
            for (int b = width - 1; b >= 0; b--) data[at++] = (byte)(entry.Second >> (b * 8));
            data[at++] = (byte)(entry.Third >> 8);
            data[at++] = (byte)entry.Third;
        }

        var index = new List<PdfObject>();
        foreach (var (first, count) in Runs(entries))
        {
            index.Add(new PdfNumber(entries[first].Number));
            index.Add(new PdfNumber(count));
        }
        var head = new PdfDictionary();
        head.Add("Type", new PdfName("XRef"));
        head.Add("W", new PdfArray([new PdfNumber(1), new PdfNumber(width), new PdfNumber(2)]));
        head.Add("Index", new PdfArray(index));
        foreach (var (key, value) in dictionary.Entries) head.Add(key, value);
        if (compress)
        {
            data = PdfFilterEncoders.Flate(data);
            head.Add("Filter", new PdfName("FlateDecode"));
        }
        writer.WriteStream(number, 0, head, data, encrypt: false);
        writer.WriteAscii($"startxref\n{start}\n%%EOF\n");
    }

    /// <summary>The trailer's /ID: the file's first string and a fresh second one.</summary>
    public static PdfArray IdPair(byte[] first) =>
        new([new PdfString(first, isHex: true), new PdfString(RandomNumberGenerator.GetBytes(16), isHex: true)]);

    /// <summary>The runs of consecutive numbers in <paramref name="entries"/> (ascending): where each starts in the list and how long it is.</summary>
    private static List<(int First, int Count)> Runs(List<XrefEntry> entries)
    {
        var runs = new List<(int, int)>();
        for (int i = 0; i < entries.Count;)
        {
            int j = i + 1;
            while (j < entries.Count && entries[j].Number == entries[j - 1].Number + 1) j++;
            runs.Add((i, j - i));
            i = j;
        }
        return runs;
    }
}
