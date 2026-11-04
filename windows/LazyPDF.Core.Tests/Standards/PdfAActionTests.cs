using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAActionTests
{
    private static byte[] LinkWith(string action, PdfALevel level = PdfALevel.A2b) =>
        StandardsKit.Compliant(level, page: "/Annots [9 0 R]", extra: pdf => pdf.Obj(9, $"<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /F 4 /Border [0 0 0] /A {action}>>"));

    [Fact]
    public void UriAndGoToActionsPass()
    {
        StandardsKit.AssertClean(LinkWith("<</S /URI /URI (http://example.com/)>>"));
        StandardsKit.AssertClean(LinkWith("<</S /GoTo /D [3 0 R /Fit]>>"));
        StandardsKit.AssertClean(LinkWith("<</S /Named /N /NextPage>>"));
    }

    [Theory]
    [InlineData("Launch")]
    [InlineData("Sound")]
    [InlineData("Movie")]
    [InlineData("ResetForm")]
    [InlineData("ImportData")]
    [InlineData("Hide")]
    [InlineData("SetOCGState")]
    [InlineData("Rendition")]
    public void ForbiddenActionTypesAreReported(string type)
    {
        Assert.Contains("6.5.1", StandardsKit.Clauses(LinkWith($"<</S /{type}>>")));
    }

    [Fact]
    public void JavaScriptIsReportedWhereverItSits()
    {
        Assert.Contains("6.5.1", StandardsKit.Clauses(LinkWith("<</S /JavaScript /JS (app.alert(1))>>")));
        Assert.Contains("6.6.1", StandardsKit.Clauses(LinkWith("<</S /JavaScript /JS (1)>>", PdfALevel.A1b), PdfALevel.A1b));
        Assert.Contains("6.5.1", StandardsKit.Clauses(StandardsKit.Compliant(catalog: "/OpenAction << /S /JavaScript /JS (1) >>")));
        Assert.Contains("6.5.1", StandardsKit.Clauses(StandardsKit.Compliant(catalog: "/Names << /JavaScript << /Names [(a) << /S /JavaScript /JS (1) >>] >> >>")));
    }

    [Fact]
    public void OnlyThePageNamedActionsAreAllowed()
    {
        Assert.Contains("6.5.1", StandardsKit.Clauses(LinkWith("<</S /Named /N /Print>>")));
        Assert.Contains("6.5.1", StandardsKit.Clauses(LinkWith("<</S /Named>>")));
        foreach (string name in new[] { "NextPage", "PrevPage", "FirstPage", "LastPage" })
            Assert.DoesNotContain("6.5.1", StandardsKit.Clauses(LinkWith($"<</S /Named /N /{name}>>")));
    }

    [Fact]
    public void AForbiddenActionLaterInAChainIsFound()
    {
        Assert.Contains("6.5.1", StandardsKit.Clauses(LinkWith("<</S /URI /URI (x) /Next [<</S /GoTo /D [3 0 R /Fit]>> <</S /Launch>>]>>")));
    }

    [Fact]
    public void TheCatalogMayNotHaveAdditionalActions()
    {
        Assert.Contains("6.5.2", StandardsKit.Clauses(StandardsKit.Compliant(catalog: "/AA << /WC << /S /URI /URI (x) >> >>")));
        Assert.Contains("6.6.2", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A1b, catalog: "/AA << /WC << /S /URI /URI (x) >> >>"), PdfALevel.A1b));
    }

    [Fact]
    public void PageTriggersAreCheckedForTheirActions()
    {
        Assert.Contains("6.5.1", StandardsKit.Clauses(StandardsKit.Compliant(page: "/AA << /O << /S /JavaScript /JS (1) >> >>")));
        Assert.DoesNotContain("6.5.1", StandardsKit.Clauses(StandardsKit.Compliant(page: "/AA << /O << /S /URI /URI (x) >> >>")));
    }
}
