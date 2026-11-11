using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizerTests
{
    private const string Picture = "/Type /XObject /Subtype /Image /Width 300 /Height 300 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode";

    // Text, a 216 dpi picture, a copy of it, a thumbnail and application data.
    private static byte[] Sample()
    {
        var picture = TestPdf.Deflate(OptimizeKit.Noise(300 * 300 * 3));
        return OptimizeKit.Build("BT /F1 12 Tf 10 180 Td (Sample text) Tj ET q 100 0 0 100 10 10 cm /Im0 Do Q q 50 0 0 50 120 10 cm /Im1 Do Q",
            "/Font <</F1 5 0 R>> /XObject <</Im0 6 0 R /Im1 7 0 R>>", pdf =>
            {
                pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
                pdf.Stream(6, Picture, picture);
                pdf.Stream(7, Picture, picture);
                pdf.Stream(8, "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", new byte[16]);
                pdf.Obj(9, "<</App <</Note (private)>>>>");
            }, pageExtra: "/Thumb 8 0 R /PieceInfo 9 0 R");
    }

    [Fact]
    public void PresetsTradeSizeForDetailInOrder()
    {
        byte[] file = Sample();
        using var document = PdfDocument.Open(file);
        int plain = document.SaveRewrite().Length;
        var codec = new OptimizeFakeCodec();
        var small = new PdfOptimizer(document, codec).Run(OptimizeOptions.For(OptimizePreset.Small));
        var balanced = new PdfOptimizer(document, codec).Run(OptimizeOptions.For(OptimizePreset.Balanced));
        var high = new PdfOptimizer(document, codec).Run(OptimizeOptions.For(OptimizePreset.HighQuality));
        Assert.True(small.SizeAfter < balanced.SizeAfter, $"{small.SizeAfter} {balanced.SizeAfter}");
        Assert.True(balanced.SizeAfter <= high.SizeAfter);
        Assert.True(high.SizeAfter <= plain);
        Assert.Equal(file.Length, small.SizeBefore);
        foreach (var result in new[] { small, balanced, high })
        {
            Assert.Equal(1, OptimizeKit.PigPages(result.Bytes));
            Assert.Equal("Sample text", OptimizeKit.PigText(result.Bytes).Trim());
            Assert.Equal(result.Bytes.Length, result.SizeAfter);
        }
        using var smallDocument = PdfDocument.Open(small.Bytes);
        Assert.Equal(1, OptimizeKit.Count(smallDocument, o => OptimizeKit.IsImage(smallDocument, o)));
        Assert.True(smallDocument.Integer(OptimizeKit.Image(smallDocument).Dictionary, "Width") < 300);
    }

    [Fact]
    public void ThePlanNamesTheStepsAndAuditsTheFile()
    {
        using var document = PdfDocument.Open(Sample());
        var plan = new PdfOptimizer(document).Plan(OptimizeOptions.For(OptimizePreset.Balanced));
        Assert.Equal(OptimizeStepKind.RemoveUnreferenced, plan.Steps[0]);
        Assert.Contains(OptimizeStepKind.DownsampleImages, plan.Steps);
        Assert.Contains(OptimizeStepKind.SubsetFonts, plan.Steps);
        Assert.DoesNotContain(OptimizeStepKind.Grayscale, plan.Steps);
        Assert.Equal(document.Length, plan.Audit.FileSize);
        Assert.True(plan.Audit.Of(SpaceKind.Images) > 100_000);
        Assert.Equal(plan.Audit.FileSize, plan.Audit.Bytes.Values.Sum());
        Assert.All(plan.Steps, step => Assert.NotEqual(step.ToString(), OptimizeText.StepName(step)));
    }

    [Fact]
    public void TheDocumentItWasGivenIsNotChanged()
    {
        using var document = PdfDocument.Open(Sample());
        string before = Describe(document);
        new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Small) with { Grayscale = true });
        Assert.Equal(before, Describe(document));
    }


    [Fact]
    public void ACancelledTokenThrowsBeforeAnyStep()
    {
        using var document = PdfDocument.Open(Sample());
        var codec = new OptimizeFakeCodec();
        using var source = new CancellationTokenSource();
        source.Cancel();
        Assert.Throws<OperationCanceledException>(() =>
            new PdfOptimizer(document, codec).Run(OptimizeOptions.For(OptimizePreset.Small), source.Token));
        Assert.Equal(0, codec.Decodes);
    }

    [Fact]
    public void CancellingInsideTheImagesStopsTheRest()
    {
        const string dictionary = "/Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode";
        byte[] file = OptimizeKit.Build("q 72 0 0 72 10 10 cm /Im0 Do Q q 72 0 0 72 10 10 cm /Im1 Do Q q 72 0 0 72 10 10 cm /Im2 Do Q q 72 0 0 72 10 10 cm /Im3 Do Q",
            "/XObject <</Im0 5 0 R /Im1 6 0 R /Im2 7 0 R /Im3 8 0 R>>", pdf =>
            {
                for (int i = 5; i <= 8; i++) pdf.Stream(i, dictionary, OptimizeKit.TinyJpeg);
            });
        using var document = PdfDocument.Open(file);
        using var source = new CancellationTokenSource();
        var codec = new OptimizeFakeCodec { OnDecode = source.Cancel };
        var options = OptimizeKit.Off with { ImageDpi = 8, ImageDpiAbove = 10 };
        Assert.Throws<OperationCanceledException>(() => new PdfOptimizer(document, codec).Run(options, source.Token));
        Assert.Equal(1, codec.Decodes);
    }

    [Fact]
    public void ALiveTokenChangesNothingInTheResult()
    {
        using var document = PdfDocument.Open(Sample());
        // The second half of the trailer id is random, so the bytes differ there and nowhere else.
        var options = OptimizeOptions.For(OptimizePreset.Balanced) with { ObjectStreams = false, DocumentId = new byte[16] };
        var codec = new OptimizeFakeCodec();
        byte[] plain = new PdfOptimizer(document, codec).Run(options).Bytes;
        using var source = new CancellationTokenSource();
        byte[] watched = new PdfOptimizer(document, codec).Run(options, source.Token).Bytes;
        int differ = plain.Zip(watched).Count(p => p.First != p.Second);
        Assert.Equal(plain.Length, watched.Length);
        Assert.InRange(differ, 0, 32);
    }

    private static string Describe(PdfDocument document) =>
        string.Join("|", document.ObjectNumbers.Select(n => $"{n}:{(document.Get(n) is PdfStream s ? s.Dictionary.ToString() + document.RawData(s).Length : document.Get(n)?.ToString())}"));

    [Fact]
    public void ATinyFileIsNeverLargerThanAPlainRewrite()
    {
        using var document = PdfDocument.Open(TestPdf.Simple(1));
        int plain = document.SaveRewrite().Length;
        foreach (var preset in Enum.GetValues<OptimizePreset>())
        {
            var result = new PdfOptimizer(document).Run(OptimizeOptions.For(preset));
            Assert.True(result.SizeAfter <= plain, $"{preset}: {result.SizeAfter} > {plain}");
        }
    }

    [Fact]
    public void ObjectStreamsAreUsedWhenTheyPay()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        var kids = string.Join(" ", Enumerable.Range(0, 60).Select(i => $"{3 + i} 0 R"));
        pdf.Obj(2, $"<</Type /Pages /Kids [{kids}] /Count 60 /MediaBox [0 0 200 200]>>");
        for (int i = 0; i < 60; i++) pdf.Obj(3 + i, "<</Type /Page /Parent 2 0 R /Resources <</ProcSet [/PDF /Text]>>>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced));
        Assert.Equal(1, result.Steps.Single(s => s.Kind == OptimizeStepKind.ObjectStreams).Count);
        Assert.True(result.SizeAfter < document.SaveRewrite().Length);
        Assert.Equal(60, OptimizeKit.PigPages(result.Bytes));
    }

    [Fact]
    public void AnEncryptedFileComesOutOpenOrEncryptedAsAsked()
    {
        var id = new byte[16];
        var security = PdfSecurity.Create("user", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, id);
        using var plain = PdfDocument.Open(Sample());
        byte[] locked = plain.SaveRewrite(new PdfSaveOptions(Security: security));
        using var document = PdfDocument.Open(locked, "user");
        Assert.True(document.IsEncrypted);

        var open = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced));
        using (var reopened = PdfDocument.Open(open.Bytes)) Assert.False(reopened.IsEncrypted);

        var again = PdfSecurity.Create("user", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, id);
        var sealedResult = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced) with { Security = again });
        using var closed = PdfDocument.Open(sealedResult.Bytes, "user");
        Assert.True(closed.IsEncrypted);
        Assert.Equal("Sample text", OptimizeKit.PigText(open.Bytes).Trim());
    }
}
