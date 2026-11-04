using System.IO.Compression;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// The original attached to the file in a container the byte search cannot see into.
public class RedactAttachmentTests
{
    private const string Word = "ZQXMARKER";

    private static byte[] Zip()
    {
        using var output = new MemoryStream();
        using (var zip = new ZipArchive(output, ZipArchiveMode.Create, true))
        {
            using var writer = new StreamWriter(zip.CreateEntry("original.txt", CompressionLevel.SmallestSize).Open(), Encoding.Latin1);
            for (int i = 0; i < 50; i++) writer.Write($"{Word} is the secret number {i}\n");
        }
        return output.ToArray();
    }

    private static byte[] CompressedPdf()
    {
        var inner = new TestPdf();
        inner.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        inner.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        inner.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        inner.Stream(4, "/Filter /FlateDecode", TestPdf.Deflate(TestPdf.Latin($"BT /F1 12 Tf 100 100 Td ({Word}) Tj ET")));
        inner.Obj(5, RedactionKit.Helvetica);
        return inner.Finish();
    }

    private static RedactionResult RedactWith(byte[] attachment)
    {
        Assert.DoesNotContain(Word, Encoding.Latin1.GetString(attachment));
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Names <</EmbeddedFiles <</Names [(original) 6 0 R]>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Stream(4, "", $"BT /F1 12 Tf 100 100 Td ({Word}) Tj ET");
        pdf.Obj(5, RedactionKit.Helvetica);
        pdf.Obj(6, "<</Type /Filespec /F (original) /EF <</F 7 0 R>>>>");
        pdf.Stream(7, "/Type /EmbeddedFile", attachment);
        using var document = PdfDocument.Open(pdf.Finish());
        return new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, Word));
    }

    [Fact]
    public void ZipHoldingTheWordIsReported() =>
        Assert.Contains(RedactWith(Zip()).Verification.Problems, p => p.Contains("attached file"));

    [Fact]
    public void PdfWithCompressedStreamsHoldingTheWordIsReported() =>
        Assert.Contains(RedactWith(CompressedPdf()).Verification.Problems, p => p.Contains("attached file"));

    [Fact]
    public void ContainerThatCannotBeOpenedIsNotCalledClean()
    {
        var broken = Zip();
        Array.Fill(broken, (byte)7, 40, broken.Length - 80);
        var problems = RedactWith(broken).Verification.Problems;
        Assert.Contains(problems, p => p.Contains("could not be opened"));
    }

    [Fact]
    public void AttachmentWithoutTheWordIsLeftAlone()
    {
        var result = RedactWith(Encoding.Latin1.GetBytes("nothing to see here"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
    }
}
