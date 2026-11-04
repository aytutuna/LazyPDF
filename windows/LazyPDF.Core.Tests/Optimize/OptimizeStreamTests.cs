using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeStreamTests
{
    private static string Words()
    {
        var rng = new Random(7);
        string[] words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet"];
        var sb = new StringBuilder();
        for (int i = 0; i < 400; i++) sb.Append($"BT /F1 10 Tf 10 {190 - i % 180} Td ({words[rng.Next(words.Length)]} {words[rng.Next(words.Length)]}) Tj ET\n");
        return sb.ToString();
    }

    private const string Font = "/Font <</F1 <</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>>>";

    [Fact]
    public void FlateStreamIsDeflatedAgainAtTheSmallestLevel()
    {
        var content = Encoding.Latin1.GetBytes(Words());
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<{Font}>>>>");
        pdf.Stream(4, "/Filter /FlateDecode", TestPdf.Deflate(content));
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { RecompressStreams = true });
        Assert.Equal(1, result.Steps.Single(s => s.Kind == OptimizeStepKind.RecompressStreams).Count);
        Assert.True(result.SizeAfter < document.SaveRewrite().Length);
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(content, after.Data((PdfStream)after.Resolve(after.Pages[0].Dictionary["Contents"])!));
    }

    [Fact]
    public void LzwWithPredictorBecomesFlateAndKeepsThePredictor()
    {
        const int w = 20, h = 20;
        var rows = new MemoryStream();
        var samples = OptimizeKit.Gradient(w, h, 3);
        for (int y = 0; y < h; y++)
        {
            rows.WriteByte(0);
            rows.Write(samples, y * w * 3, w * 3);
        }
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <</XObject <</Im0 5 0 R>>>>>>");
        pdf.Stream(4, "", "q 100 0 0 100 0 0 cm /Im0 Do Q");
        pdf.Stream(5, $"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /LZWDecode /DecodeParms <</Predictor 12 /Colors 3 /Columns {w} /EarlyChange 0>>",
            PdfFilterEncoders.Lzw(rows.ToArray(), earlyChange: false));
        using var document = PdfDocument.Open(pdf.Finish());
        Assert.Equal(samples, document.Data(OptimizeKit.Image(document)));

        var result = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.HighQuality) with { ImageDpi = 0, BilevelTolerance = -1 });
        Assert.Equal(1, result.Steps.Single(s => s.Kind == OptimizeStepKind.ConvertOldFilters).Count);
        using var after = PdfDocument.Open(result.Bytes);
        var image = OptimizeKit.Image(after);
        Assert.Equal("FlateDecode", after.Name(image.Dictionary, "Filter"));
        Assert.Equal(12, after.Integer(after.Dict(image.Dictionary, "DecodeParms"), "Predictor"));
        Assert.Null(after.Dict(image.Dictionary, "DecodeParms")?["EarlyChange"]);
        Assert.Equal(samples, after.Data(image));
    }

    [Fact]
    public void StreamThatDoesNotDecodeIsLeftAlone()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<>> /Junk 5 0 R>>");
        pdf.Stream(4, "", "0 0 10 10 re f");
        byte[] junk = OptimizeKit.Noise(300);
        pdf.Stream(5, "/Filter /FlateDecode", junk);
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off with { RecompressStreams = true });
        using var after = PdfDocument.Open(result.Bytes);
        Assert.Equal(0, result.Steps.Single(s => s.Kind == OptimizeStepKind.RecompressStreams).Count);
        Assert.Equal(junk, after.RawData((PdfStream)after.Resolve(after.Pages[0].Dictionary["Junk"])!));
    }
}
