using System.IO.Compression;
using System.Text;
using LazyPDF.Core;

namespace LazyPDF.Core.Tests;

/// <summary>Builds small PDF files byte by byte, so that a test can break exactly one thing.</summary>
internal sealed class TestPdf
{
    private readonly MemoryStream _bytes = new();
    private readonly SortedDictionary<int, long> _offsets = [];

    public TestPdf(string header = "%PDF-1.4\n") => Write(header);

    public long Position => _bytes.Length;

    public static byte[] Latin(string text) => Encoding.Latin1.GetBytes(text);

    public static string Text(byte[] bytes) => Encoding.Latin1.GetString(bytes);

    public static byte[] Deflate(byte[] data)
    {
        using var output = new MemoryStream();
        using (var z = new ZLibStream(output, CompressionLevel.Fastest, leaveOpen: true)) z.Write(data);
        return output.ToArray();
    }

    public TestPdf Write(string text)
    {
        _bytes.Write(Latin(text));
        return this;
    }

    public TestPdf Obj(int number, string body)
    {
        _offsets[number] = Position;
        return Write($"{number} 0 obj\n{body}\nendobj\n");
    }

    /// <summary>A stream object; <paramref name="length"/> is what /Length says (the data's length when null, omitted when negative).</summary>
    public TestPdf Stream(int number, string entries, byte[] data, int? length = null, bool endstream = true)
    {
        _offsets[number] = Position;
        string declared = length is < 0 ? "" : $"/Length {length ?? data.Length}";
        Write($"{number} 0 obj\n<<{entries} {declared}>>\nstream\n");
        _bytes.Write(data);
        return Write(endstream ? "\nendstream\nendobj\n" : "\nendobj\n");
    }

    public TestPdf Stream(int number, string entries, string data, int? length = null, bool endstream = true) => Stream(number, entries, Latin(data), length, endstream);

    /// <summary>The classic table and trailer, and the file; <paramref name="shift"/> moves every offset by that much.</summary>
    public byte[] Finish(string trailer = "/Root 1 0 R", int shift = 0, string startxref = "")
    {
        long start = Position;
        int size = _offsets.Keys.Max() + 1;
        var sb = new StringBuilder($"xref\n0 {size}\n0000000000 65535 f \n");
        for (int n = 1; n < size; n++)
        {
            sb.Append(_offsets.TryGetValue(n, out long offset) ? $"{offset + shift:D10} 00000 n \n" : "0000000000 00000 f \n");
        }
        sb.Append($"trailer\n<</Size {size} {trailer}>>\nstartxref\n{(startxref.Length > 0 ? startxref : start.ToString())}\n%%EOF\n");
        return [.. _bytes.ToArray(), .. Latin(sb.ToString())];
    }

    public byte[] FinishWithoutXref() => _bytes.ToArray();

    /// <summary>A catalog (1), a page tree (2) and <paramref name="count"/> pages (3...), each with a content stream after them.</summary>
    public static TestPdf WithPages(int count)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", Enumerable.Range(0, count).Select(i => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count {count} /MediaBox [0 0 200 300]>>");
        for (int i = 0; i < count; i++) pdf.Obj(3 + i, $"<</Type /Page /Parent 2 0 R /Contents {3 + count + i} 0 R>>");
        for (int i = 0; i < count; i++) pdf.Stream(3 + count + i, "", $"BT /F1 12 Tf ({i + 1}) Tj ET");
        return pdf;
    }

    public static byte[] Simple(int count = 2) => WithPages(count).Finish();

    /// <summary>The file with the first <paramref name="find"/> replaced by <paramref name="replacement"/>.</summary>
    public static byte[] Replace(byte[] file, string find, string replacement)
    {
        string text = Text(file);
        int at = text.IndexOf(find, StringComparison.Ordinal);
        if (at < 0) throw new InvalidOperationException($"\"{find}\" is not in the file.");
        return Latin(text[..at] + replacement + text[(at + find.Length)..]);
    }
}
