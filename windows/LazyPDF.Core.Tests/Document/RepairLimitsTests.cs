using System.Diagnostics;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RepairLimitsTests
{
    [Fact]
    public void TrailersInsideAValueThatIsNotADictionaryAreScannedOnce()
    {
        const int depth = 40_000;
        var text = new StringBuilder("%PDF-1.4\n");
        for (int i = 0; i < depth; i++) text.Append("trailer (");
        text.Append(')', depth);
        byte[] file = TestPdf.Latin(text.ToString());

        var timer = Stopwatch.StartNew();
        Assert.Throws<PdfReadException>(() => PdfDocument.Open(file));
        Assert.True(timer.Elapsed < TimeSpan.FromSeconds(3), $"took {timer.Elapsed}");
    }

    [Fact]
    public void RepairWithNoObjectNumbersLeftIsAReadErrorNotAnInvalidOperation()
    {
        byte[] file = TestPdf.Latin("%PDF-1.4\n8388607 0 obj\n<</Type/Page>>\nendobj\n");
        Assert.Throws<PdfReadException>(() => PdfDocument.Open(file));
    }

    [Fact]
    public void ASharedXrefStreamIsReadOncePerFile()
    {
        const int entries = 200_000, sections = 2000;
        var pdf = TestPdf.WithPages(1);
        long stream = pdf.Position;
        var rows = new byte[entries * 5];
        pdf.Stream(9, $"/Type /XRef /Size {entries + 10} /Index [10 {entries}] /W [1 3 1] /Filter /FlateDecode", TestPdf.Deflate(rows));
        byte[] first = pdf.Finish("/Root 1 0 R");
        var text = new StringBuilder();
        long previous = TestPdf.Text(first).LastIndexOf("xref\n0", StringComparison.Ordinal);
        long end = first.Length;
        for (int i = 0; i < sections; i++)
        {
            long at = end + text.Length;
            text.Append($"xref\n0 1\n0000000000 65535 f \ntrailer\n<</Size {entries + 10} /Root 1 0 R /Prev {previous} /XRefStm {stream}>>\n");
            text.Append($"startxref\n{at}\n%%EOF\n");
            previous = at;
        }
        byte[] file = [.. first, .. TestPdf.Latin(text.ToString())];

        var timer = Stopwatch.StartNew();
        var document = PdfDocument.Open(file);
        Assert.Single(document.Pages);
        Assert.True(timer.Elapsed < TimeSpan.FromSeconds(5), $"took {timer.Elapsed}");
    }
}
