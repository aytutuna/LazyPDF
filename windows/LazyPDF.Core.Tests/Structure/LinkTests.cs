using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LinkTests
{
    private static PdfDocument Sample() => StructureFixtures.File("", pdf =>
    {
        pdf.Obj(20, "<</Type /Annot /Subtype /Link /Rect [10 20 110 40] /Dest [4 0 R /Fit]>>");
        pdf.Obj(21, "<</Type /Annot /Subtype /Link /Rect [150 40 50 20] /A <</S /URI /URI (https://example.com)>>>>");
        pdf.Obj(22, "<</Type /Annot /Subtype /Link /Rect [0 0 5 5] /A <</S /GoTo /D [5 0 R /FitH 9]>>>>");
        pdf.Obj(23, "<</Type /Annot /Subtype /Text /Rect [0 0 5 5] /Contents (note)>>");
        pdf.Obj(24, "<</Type /Annot /Subtype /Link>>");
        pdf.Obj(25, "<</Type /Annot /Subtype /Link /Rect [0 0 5 5] /A <</S /Launch /F (x.exe)>>>>");
    }, pageEntries: "/Annots [20 0 R 21 0 R 22 0 R 23 0 R 24 0 R 25 0 R 99 0 R 7]");

    [Fact]
    public void ReadsLinksOnly()
    {
        var document = Sample();
        var links = PdfLinks.Read(document, document.Pages[0]);
        Assert.Equal(4, links.Count);
        Assert.Equal(new PdfRect(10, 20, 110, 40), links[0].Rect);
        Assert.Equal(1, links[0].Destination!.PageIndex);
        Assert.Null(links[0].Action);
        Assert.Equal("https://example.com", links[1].Uri);
        Assert.Equal(new PdfRect(50, 20, 150, 40), links[1].Rect);
        Assert.Null(links[1].Destination);
        Assert.Equal(2, links[2].Destination!.PageIndex);
        Assert.IsType<GoToAction>(links[2].Action);
        Assert.IsType<LaunchAction>(links[3].Action);
        Assert.Equal(20, links[0].Reference!.Number);
    }

    [Fact]
    public void PageWithoutAnnotationsHasNoLinks()
    {
        var document = Sample();
        document.Pages[1].Dictionary.Remove("Annots");
        Assert.Empty(PdfLinks.Read(document, document.Pages[1]));
    }

    [Fact]
    public void AddsDestinationAndUriLinks()
    {
        var document = StructureFixtures.Open();
        var page = document.Pages[0];
        var toPage = PdfLinks.Add(document, page, new PdfRect(10, 10, 60, 30), new PdfDestination(2, DestinationFit.FitH, Top: 5));
        var toWeb = PdfLinks.AddUri(document, page, new PdfRect(70, 10, 120, 30), "https://example.com/é");
        var other = PdfLinks.Add(document, document.Pages[1], new PdfRect(1, 1, 2, 2), new NamedAction("NextPage"));

        var reopened = StructureFixtures.Reopen(document);
        var links = PdfLinks.Read(reopened, reopened.Pages[0]);
        Assert.Equal(2, links.Count);
        Assert.Equal(2, links[0].Destination!.PageIndex);
        Assert.Equal("https://example.com/é", links[1].Uri);
        Assert.Equal(new PdfRect(70, 10, 120, 30), links[1].Rect);
        Assert.IsType<NamedAction>(PdfLinks.Read(reopened, reopened.Pages[1]).Single().Action);
        Assert.NotEqual(toPage.Number, toWeb.Number);
        Assert.NotEqual(toWeb.Number, other.Number);
    }

    [Fact]
    public void PdfPigSeesTheAddedLink()
    {
        // The fixture pages from Open draw text without a font, which PdfPig refuses; these have no content.
        var document = StructureFixtures.File("");
        PdfLinks.AddUri(document, document.Pages[0], new PdfRect(10, 10, 60, 30), "https://example.com");
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        var annotation = Assert.Single(pig.GetPage(1).GetAnnotations());
        Assert.Equal(UglyToad.PdfPig.Annotations.AnnotationType.Link, annotation.Type);
    }

    [Fact]
    public void AddsToAnIndirectAnnotsArray()
    {
        var document = StructureFixtures.File("", pdf => pdf.Obj(30, "[]"), pageEntries: "/Annots 30 0 R");
        PdfLinks.AddUri(document, document.Pages[0], new PdfRect(1, 1, 5, 5), "http://x");
        Assert.Single(((PdfArray)document.Get(30)!).Items);
        var reopened = StructureFixtures.Reopen(document);
        Assert.Single(PdfLinks.Read(reopened, reopened.Pages[0]));
    }

    [Fact]
    public void RemovesALink()
    {
        var document = Sample();
        var page = document.Pages[0];
        var links = PdfLinks.Read(document, page);
        Assert.True(PdfLinks.Remove(document, page, links[1].Reference!));
        Assert.Null(document.Get(21));
        Assert.False(PdfLinks.Remove(document, page, links[1].Reference!));
        Assert.Equal(3, PdfLinks.Read(document, page).Count);
        Assert.Equal(3, PdfLinks.Read(StructureFixtures.Reopen(document), document.Pages[0]).Count);
    }

    [Fact]
    public void RemoveOnPageWithoutAnnotsIsFalse()
    {
        var document = StructureFixtures.Open();
        Assert.False(PdfLinks.Remove(document, document.Pages[0], new PdfReference(9, 0)));
    }

    [Fact]
    public void LinkToAPageThatIsGoneCannotBeAdded()
    {
        var document = StructureFixtures.Open();
        Assert.Throws<ArgumentException>(() => PdfLinks.Add(document, document.Pages[0], new PdfRect(0, 0, 1, 1), new PdfDestination(10)));
    }
}
