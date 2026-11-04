using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAOptionalContentTests
{
    private static byte[] WithLayers(string properties, PdfALevel level = PdfALevel.A2b) =>
        StandardsKit.Compliant(level, catalog: $"/OCProperties {properties}", extra: pdf => pdf.Obj(9, "<</Type /OCG /Name (Layer)>>"));

    private const string Good = "<< /OCGs [9 0 R] /D << /Name (Default) /Order [9 0 R] >> >>";

    [Fact]
    public void Part1ForbidsOptionalContentAndLaterPartsAllowIt()
    {
        Assert.Contains("6.1.13", StandardsKit.Clauses(WithLayers(Good, PdfALevel.A1b), PdfALevel.A1b));
        StandardsKit.AssertClean(WithLayers(Good));
        StandardsKit.AssertClean(WithLayers(Good, PdfALevel.A3b), PdfALevel.A3b);
    }

    [Fact]
    public void EveryConfigurationNeedsAUniqueName()
    {
        Assert.Contains("6.9", StandardsKit.Clauses(WithLayers("<< /OCGs [9 0 R] /D << /Order [9 0 R] >> >>")));
        Assert.Contains(StandardsKit.Check(WithLayers("<< /OCGs [9 0 R] /D << /Name (A) >> /Configs [<< /Name (A) >>] >>")).Issues, i => i.Message.Contains("same name"));
        Assert.DoesNotContain("6.9", StandardsKit.Clauses(WithLayers("<< /OCGs [9 0 R] /D << /Name (A) >> /Configs [<< /Name (B) >>] >>")));
    }

    [Fact]
    public void AnAutomaticStateIsReported()
    {
        Assert.Contains(StandardsKit.Check(WithLayers("<< /OCGs [9 0 R] /D << /Name (A) /AS [<< /Event /View >>] >> >>")).Issues, i => i.Message.Contains("/AS"));
    }

    [Fact]
    public void TheOrderHasToListEveryGroup()
    {
        Assert.Contains(StandardsKit.Check(WithLayers("<< /OCGs [9 0 R] /D << /Name (A) /Order [] >> >>")).Issues, i => i.Message.Contains("/Order"));
        StandardsKit.AssertClean(WithLayers("<< /OCGs [9 0 R] /D << /Name (A) /Order [[(Group) 9 0 R]] >> >>"));
    }
}
