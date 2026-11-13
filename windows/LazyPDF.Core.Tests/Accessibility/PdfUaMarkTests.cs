using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfUaMarkTests
{
    private static readonly byte[] Unmarked = PdfUaKit.Build(xmp: PdfUaKit.Packet(ua: false), viewer: "");

    private static PdfUaMarkResult Mark(PdfDocument document) => PdfUaValidator.Mark(document, PdfUaKit.Date);

    private static PdfDocument Reopen(PdfDocument document) => PdfDocument.Open(document.SaveRewrite());

    [Fact]
    public void AFileThatPassesButForTheMarksIsMarked()
    {
        using var document = PdfDocument.Open(Unmarked);

        var result = Mark(document);

        Assert.True(result.Marked);
        Assert.True(result.Blocking.IsValid);
        using var saved = Reopen(document);
        var report = PdfUaValidator.Validate(saved);
        Assert.True(report.IsValid, PdfUaKit.Describe(report));
        Assert.True(ViewerSettings.Read(saved).DisplayDocTitle);
    }

    [Fact]
    public void AFileWithoutMetadataGetsAPacketFromInfo()
    {
        using var document = PdfDocument.Open(PdfUaKit.Build(xmp: ""));
        Assert.Contains("06-001", PdfUaValidator.Validate(document).Issues.Select(i => i.Condition));

        Assert.True(Mark(document).Marked);

        using var saved = Reopen(document);
        Assert.True(PdfUaValidator.Validate(saved).IsValid);
        Assert.Equal("Title", DocumentMetadata.Read(saved).Title);
    }

    [Fact]
    public void AFileThatFailsAnythingElseIsLeftAlone()
    {
        using var document = PdfDocument.Open(PdfUaKit.Build(xmp: PdfUaKit.Packet(ua: false), viewer: "", lang: ""));

        var result = Mark(document);

        Assert.False(result.Marked);
        Assert.Contains("11-006", result.Blocking.Issues.Select(i => i.Condition));
        Assert.DoesNotContain(result.Blocking.Issues, i => i.Condition is "06-002" or "07-001");
        Assert.False(ViewerSettings.Read(document).DisplayDocTitle);
        Assert.DoesNotContain("pdfuaid", System.Text.Encoding.UTF8.GetString(document.Data(document.Stream(document.Catalog, "Metadata")!)));
    }

    [Fact]
    public void WithoutATitleThereIsNothingToShow()
    {
        using var document = PdfDocument.Open(PdfUaKit.Build(xmp: PdfUaKit.Packet(ua: false, title: false), viewer: "", info: "<</Creator (Test)>>"));

        var result = Mark(document);

        Assert.False(result.Marked);
        Assert.Equal(["06-003"], result.Blocking.Issues.Select(i => i.Condition));
    }

    [Fact]
    public void ATitleInInfoReachesTheXmp()
    {
        using var document = PdfDocument.Open(PdfUaKit.Build(xmp: PdfUaKit.Packet(ua: false, title: false), viewer: ""));

        Assert.True(Mark(document).Marked);

        using var saved = Reopen(document);
        Assert.True(PdfUaValidator.Validate(saved).IsValid);
    }

    [Fact]
    public void MarkingTwiceChangesNothingTheSecondTime()
    {
        using var document = PdfDocument.Open(Unmarked);
        Mark(document);
        using var once = Reopen(document);

        Assert.True(Mark(once).Marked);

        string packet = System.Text.Encoding.UTF8.GetString(once.Data(once.Stream(once.Catalog, "Metadata")!));
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(packet, "<pdfuaid:part>"));
    }

    [Fact]
    public void APdfAFileStaysPdfAWithTheExtensionSchema()
    {
        byte[] file = StandardsKit.Tagged(PdfALevel.A2b);
        using (var before = PdfDocument.Open(file)) Assert.True(PdfAValidator.Validate(before, PdfALevel.A2b).IsValid);
        using var document = PdfDocument.Open(file);

        Assert.True(Mark(document).Marked);

        using var saved = Reopen(document);
        Assert.True(PdfUaValidator.Validate(saved).IsValid);
        var pdfa = PdfAValidator.Validate(saved, PdfALevel.A2b);
        Assert.True(pdfa.IsValid, string.Join("\n", pdfa.Issues.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        Assert.Contains("PDF/UA identification schema", System.Text.Encoding.UTF8.GetString(saved.Data(saved.Stream(saved.Catalog, "Metadata")!)));
    }
}
