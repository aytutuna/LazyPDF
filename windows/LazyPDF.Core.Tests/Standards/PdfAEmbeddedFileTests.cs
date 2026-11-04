using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAEmbeddedFileTests
{
    private static byte[] WithAttachment(byte[] content, string spec = "", PdfALevel level = PdfALevel.A2b, string stream = "/Type /EmbeddedFile") =>
        StandardsKit.Compliant(level, catalog: "/Names << /EmbeddedFiles << /Names [(a.dat) 9 0 R] >> >>", extra: pdf =>
        {
            pdf.Obj(9, $"<</Type /Filespec /F (a.dat) /UF (a.dat) /EF << /F 10 0 R >> {spec}>>");
            pdf.Stream(10, stream, content);
        });

    private static readonly byte[] Text = "hello"u8.ToArray();

    [Fact]
    public void Part1AndPart4ForbidEmbeddedFiles()
    {
        Assert.Contains("6.1.11", StandardsKit.Clauses(WithAttachment(Text, level: PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains("6.8", StandardsKit.Clauses(WithAttachment(Text, level: PdfALevel.A4), PdfALevel.A4));
    }

    [Fact]
    public void Part2OnlyAllowsFilesThatAreThemselvesPdfA()
    {
        Assert.Contains(StandardsKit.Check(WithAttachment(Text)).Issues, i => i.Clause == "6.8" && i.Message.Contains("not a PDF/A"));
        StandardsKit.AssertClean(WithAttachment(StandardsKit.Compliant(PdfALevel.A2b)));
    }

    [Fact]
    public void Part3AllowsAnyFileWithARelationshipAndAType()
    {
        Assert.Contains(StandardsKit.Check(WithAttachment(Text, level: PdfALevel.A3b), PdfALevel.A3b).Issues, i => i.Message.Contains("AFRelationship"));
        Assert.Contains(StandardsKit.Check(WithAttachment(Text, "/AFRelationship /Data", PdfALevel.A3b), PdfALevel.A3b).Issues, i => i.Message.Contains("MIME"));
        StandardsKit.AssertClean(WithAttachment(Text, "/AFRelationship /Data", PdfALevel.A3b, "/Type /EmbeddedFile /Subtype /text#2Fplain"), PdfALevel.A3b);
    }
}
