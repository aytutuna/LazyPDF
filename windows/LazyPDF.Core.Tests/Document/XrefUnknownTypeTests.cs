using System.Text;
using System.Text.RegularExpressions;
using Xunit;

namespace LazyPDF.Core.Tests;

public class XrefUnknownTypeTests
{
    // An update whose cross-reference stream lists object 5 with the given type bytes.
    private static byte[] Updated(string entry)
    {
        byte[] file = PageTestFiles.Make(1);
        string previous = Regex.Matches(Encoding.Latin1.GetString(file), @"startxref\s+(\d+)")[^1].Groups[1].Value;
        int at = file.Length;
        string data = entry + "\u0001" + (char)(at >> 8) + (char)(at & 255) + "\0";
        string update = $"20 0 obj\n<</Type /XRef /Size 21 /W [1 2 1] /Index [5 1 20 1] /Root 1 0 R /Prev {previous} /Length {data.Length}>>\nstream\n{data}\nendstream\nendobj\nstartxref\n{at}\n%%EOF\n";
        return [.. file, .. Encoding.Latin1.GetBytes(update)];
    }

    [Fact]
    public void EntryOfAnUnknownTypeReadsAsNullAndHidesTheOlderOne()
    {
        using var document = PdfDocument.Open(Updated("\u0003\0\0\0"));

        Assert.Null(document.Get(5));
    }

    [Fact]
    public void InUseEntryAtOffsetZeroReadsAsNull()
    {
        using var document = PdfDocument.Open(Updated("\u0001\0\0\0"));

        Assert.Null(document.Get(5));
    }
}
