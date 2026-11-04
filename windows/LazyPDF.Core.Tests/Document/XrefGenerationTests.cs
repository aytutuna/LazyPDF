using System.Text;
using System.Text.RegularExpressions;
using Xunit;

namespace LazyPDF.Core.Tests;

public class XrefGenerationTests
{
    // An update that lists an object again at generation 1 over the same bytes.
    private static byte[] Relisted(byte[] file, int number)
    {
        string text = Encoding.Latin1.GetString(file);
        string previous = Regex.Matches(text, @"startxref\s+(\d+)")[^1].Groups[1].Value;
        string body = Regex.Match(text, $@"(?<![0-9]){number} 0 obj(.*?)endobj", RegexOptions.Singleline).Groups[1].Value;
        int at = file.Length;
        int xref = at + $"{number} 1 obj{body}endobj\n".Length;
        string data = "\u0001" + (char)(at >> 8) + (char)(at & 255) + "\u0001" + "\u0001" + (char)(xref >> 8) + (char)(xref & 255) + "\0";
        string update = $"{number} 1 obj{body}endobj\n20 0 obj\n<</Type /XRef /Size 21 /W [1 2 1] /Index [{number} 1 20 1] /Root 1 0 R /Prev {previous} /Length {data.Length}>>\nstream\n{data}\nendstream\nendobj\nstartxref\n{xref}\n%%EOF\n";
        return [.. file, .. Encoding.Latin1.GetBytes(update)];
    }

    [Theory]
    [InlineData(3)]
    [InlineData(5)]
    [InlineData(6)]
    public void AnObjectListedAgainAtAnotherGenerationIsAChangeEvenWithTheSameBytes(int number)
    {
        byte[] file = PageTestFiles.Make(2);
        using var before = PdfDocument.Open(file);
        using var after = PdfDocument.Open(Relisted(file, number));

        var report = ChangeDetector.Compare(before, after, 2, [], new HashSet<long>());

        Assert.Contains(report.Changes, c => c.Object == number && !c.Allowed);
    }
}
