using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAStructureTests
{
    private const string Binary = "%\u00E2\u00E3\u00CF\u00D3\n";

    [Fact]
    public void ACompliantFilePassesEveryPart()
    {
        foreach (var level in new[] { PdfALevel.A1b, PdfALevel.A2b, PdfALevel.A2u, PdfALevel.A3b, PdfALevel.A3u, PdfALevel.A4 })
            StandardsKit.AssertClean(StandardsKit.Compliant(level), level);
    }

    [Fact]
    public void AHeaderVersionOutsideTheRangeIsReported()
    {
        var file = StandardsKit.Compliant(header: "%PDF-1.9\n" + Binary);
        Assert.Contains("6.1.2", StandardsKit.Clauses(file));
        Assert.DoesNotContain("6.1.2", StandardsKit.Clauses(StandardsKit.Compliant(header: "%PDF-1.3\n" + Binary)));
    }

    [Fact]
    public void AHeaderWithoutTheBinaryCommentIsReported()
    {
        var issues = StandardsKit.Check(StandardsKit.Compliant(header: "%PDF-1.7\n")).Issues;
        Assert.Contains(issues, i => i.Clause == "6.1.2" && i.Where == "File header");
    }

    [Fact]
    public void Part4NeedsAHeaderOfVersion2()
    {
        StandardsKit.AssertClean(StandardsKit.Compliant(PdfALevel.A4), PdfALevel.A4);
        Assert.Contains("6.1.2", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A2b), PdfALevel.A4));
    }

    [Fact]
    public void DataAfterTheLastEofIsReportedButOneLineBreakIsNot()
    {
        byte[] good = StandardsKit.Compliant();
        Assert.DoesNotContain("6.1.3", StandardsKit.Clauses(good));
        Assert.Contains("6.1.3", StandardsKit.Clauses([.. good, .. "junk"u8.ToArray()]));
        Assert.Contains("6.1.3", StandardsKit.Clauses([.. good, 10, 10]));
    }

    [Fact]
    public void ATrailerWithoutAnIdIsReported()
    {
        var pdf = new TestPdf("%PDF-1.7\n" + Binary);
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        var issues = StandardsKit.Check(pdf.Finish()).Issues;
        Assert.Contains(issues, i => i.Clause == "6.1.3" && i.Message.Contains("/ID"));
    }

    [Fact]
    public void AnEncryptedFileIsReported()
    {
        var id = new byte[16];
        var security = PdfSecurity.Create("u", "o", PdfPermissions.All, PdfCryptStrength.Aes256, id);
        byte[] file = StandardsKit.Edited(StandardsKit.Compliant(), d => { });
        using var document = PdfDocument.Open(file);
        byte[] locked = document.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));
        using var again = PdfDocument.Open(locked, "u");
        Assert.Contains(PdfAValidator.Validate(again, PdfALevel.A2b).Issues, i => i.Clause == "6.1.3" && i.Message.Contains("encrypted"));
    }

    [Fact]
    public void AStreamKeywordFollowedByACarriageReturnAloneIsReported()
    {
        string text = StandardsKit.Latin(StandardsKit.Compliant());
        int at = text.IndexOf("stream\n0 0 1 rg", StringComparison.Ordinal);
        string broken = text[..at] + "stream\r" + text[(at + 7)..];
        Assert.Contains(StandardsKit.Check(StandardsKit.Bytes(broken)).Issues, i => i.Clause == "6.1.7" && i.Message.Contains("CRLF"));
    }

    [Fact]
    public void AStreamLengthThatDoesNotMatchIsReported()
    {
        string text = StandardsKit.Latin(StandardsKit.Compliant());
        int length = "0 0 1 rg 20 20 100 100 re f".Length;
        string broken = text.Replace($"/Length {length}", $"/Length {length - 1}", StringComparison.Ordinal);
        Assert.Contains(StandardsKit.Check(StandardsKit.Bytes(broken)).Issues, i => i.Clause == "6.1.7" && i.Message.Contains("/Length"));
    }

    [Fact]
    public void ForbiddenStreamKeysAndFiltersAreReported()
    {
        byte[] file = StandardsKit.Edited(StandardsKit.Compliant(), d =>
        {
            var content = (PdfStream)d.Resolve(d.Pages[0].Dictionary["Contents"])!;
            content.Dictionary["F"] = new PdfString("a.txt"u8.ToArray(), false);
            content.Data = PdfFilterEncoders.Lzw("0 0 1 rg 20 20 100 100 re f"u8);
            content.Dictionary["Filter"] = new PdfName("LZWDecode");
        });
        var issues = StandardsKit.Check(file).Issues;
        Assert.Contains(issues, i => i.Clause == "6.1.7" && i.Message.Contains("/F"));
        Assert.Contains(issues, i => i.Clause == "6.1.10" && i.Message.Contains("LZW"));
    }

    [Fact]
    public void ObjectStreamsAreOnlyAllowedFromPart2()
    {
        using var document = PdfDocument.Open(StandardsKit.Compliant());
        byte[] packed = document.SaveRewrite(new PdfSaveOptions(UseObjectStreams: true));
        Assert.Contains("6.1.4", StandardsKit.Clauses(packed, PdfALevel.A1b));
        Assert.DoesNotContain("6.1.4", StandardsKit.Clauses(packed, PdfALevel.A2b));
    }

    [Fact]
    public void ImplementationLimitsAreReported()
    {
        string longName = new('a', 130);
        Assert.Contains("6.1.13", StandardsKit.Clauses(StandardsKit.Compliant(catalog: $"/Key /{longName}")));
        string nested = string.Concat(Enumerable.Repeat("q ", 29)) + string.Concat(Enumerable.Repeat("Q ", 29));
        Assert.Contains("6.1.13", StandardsKit.Clauses(StandardsKit.Compliant(content: nested)));
        Assert.DoesNotContain("6.1.13", StandardsKit.Clauses(StandardsKit.Compliant(content: string.Concat(Enumerable.Repeat("q ", 28)) + string.Concat(Enumerable.Repeat("Q ", 28)))));
        Assert.Contains("6.1.13", StandardsKit.Clauses(StandardsKit.Compliant(catalog: "/Big 3000000000")));
    }

    [Fact]
    public void ADamagedCrossReferenceTableIsReported()
    {
        string text = StandardsKit.Latin(StandardsKit.Compliant());
        int start = text.LastIndexOf("startxref\n", StringComparison.Ordinal);
        string broken = text[..(start + 10)] + "9999\n%%EOF\n";
        Assert.Contains("6.1.4", StandardsKit.Clauses(StandardsKit.Bytes(broken)));
    }
}
