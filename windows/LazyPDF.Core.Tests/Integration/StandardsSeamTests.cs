using Xunit;

namespace LazyPDF.Core.Tests;

public class StandardsSeamTests
{
    private static PdfAConversion Convert(byte[] file, PdfALevel level, string? password = null) =>
        new PdfAConverter(new SystemFonts()).Convert(file, level, StandardsKit.Date, password);

    private static void AssertValid(byte[] bytes, PdfALevel level)
    {
        var report = PdfAValidator.Validate(PdfDocument.Open(bytes), level);
        Assert.True(report.IsValid, string.Join("; ", report.Issues.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        IntegrationFiles.ReadBack(bytes);
    }

    [Theory]
    [InlineData(PdfALevel.A1b)]
    [InlineData(PdfALevel.A2b)]
    [InlineData(PdfALevel.A2u)]
    public void ARedactedFileConvertsAndTheTextStaysGone(PdfALevel level)
    {
        using var source = PdfDocument.Open(SignatureKit.Plain(1));
        var redacted = new PdfRedactor(source, new ArialSource()).Apply([RedactionKit.MarkOf(source, 0, "Contract", overlay: "REMOVED")]);
        Assert.True(redacted.Verification.IsClean);

        var converted = Convert(redacted.Bytes, level);
        Assert.True(converted.IsClean, string.Join("; ", converted.Remaining.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        AssertValid(converted.Bytes!, level);
        Assert.False(RedactionKit.Holds(converted.Bytes!, "Contract"));
        using var pig = UglyToad.PdfPig.PdfDocument.Open(converted.Bytes!);
        Assert.Contains("page 1", pig.GetPage(1).Text);
        Assert.DoesNotContain("Contract", pig.GetPage(1).Text);
    }

    [Fact]
    public async Task AFileWithAnOcrLayerConvertsAndKeepsItsWords()
    {
        var session = PdfEditSession.Open(OcrKit.ScanBytes(1));
        var result = await PdfSearchable.RunAsync(session, new FakeRecognizer(OcrKit.Words(dpi: 144)), new FakeRenderer(session.Document), new OcrOptions(Dpi: 144));
        Assert.True(result.Committed);

        var converted = Convert(session.Current.ToArray(), PdfALevel.A2u);
        Assert.True(converted.IsClean, string.Join("; ", converted.Remaining.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        AssertValid(converted.Bytes!, PdfALevel.A2u);

        var again = PdfDocument.Open(converted.Bytes!);
        string text = TextPage.Create(again, again.Pages[0]).Text;
        Assert.All(OcrKit.WordBoxes, w => Assert.Contains(w.Text, text));
    }
}
