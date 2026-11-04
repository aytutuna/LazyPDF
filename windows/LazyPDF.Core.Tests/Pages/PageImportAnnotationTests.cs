using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageImportAnnotationTests
{
    // Page 4 (index 0) of PageImportTests.Source with six annotations; page 5 is index 1, page 6 index 2.
    private const string Annots = "/Annots [40 0 R 41 0 R 42 0 R 43 0 R 44 0 R 45 0 R 46 0 R]";

    private static PdfDocument Source() => PdfDocument.Open(PageImportTests.Source(Annots, "/Dests <</five [5 0 R /Fit]>>", pdf => pdf
        .Obj(40, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [5 0 R /Fit]>>")
        .Obj(41, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [6 0 R /Fit]>>>>")
        .Obj(42, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest /five>>")
        .Obj(43, "<</Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (note) /Popup 44 0 R /P 4 0 R /StructParent 3>>")
        .Obj(44, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 43 0 R /Open true>>")
        .Obj(45, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://example.com)>>>>")
        .Obj(46, "<</Type /Annot /Subtype /Popup /Rect [50 50 100 100] /Parent 99 0 R>>")));

    private static List<PdfDictionary> AnnotationsOf(PdfDocument document, int page) =>
        [.. document.Array(document.Pages[page].Dictionary, "Annots")?.Items.Select(i => (PdfDictionary)document.Resolve(i)!) ?? []];

    private static string Subtypes(IEnumerable<PdfDictionary> annotations) =>
        string.Join(",", annotations.Select(a => ((PdfName)a["Subtype"]!).Value + (a["Dest"] is not null ? "+D" : a["A"] is PdfDictionary { } ? "+A" : "")));

    [Fact]
    public void LinksToPagesThatCameAcrossFollowThemAndTheOthersAreDropped()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0, 1], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var annotations = AnnotationsOf(again, 1);
        // The link to page 5 (kept, repointed), the named one (made explicit), the note and its popup, the web link; not the link to page 6 nor the orphan popup.
        Assert.Equal("Link+D,Link+D,Text,Popup,Link+A", Subtypes(annotations));
        Assert.Equal(again.Pages[2].Reference, PageDestinations.PageOf(again, annotations[0]["Dest"]));
        Assert.Equal(again.Pages[2].Reference, PageDestinations.PageOf(again, annotations[1]["Dest"]));
        Assert.Equal("/Fit", ((PdfArray)again.Resolve(annotations[0]["Dest"])!).Items[1].ToString());
    }

    [Fact]
    public void LinksToPagesThatStayBehindAreDroppedAndNothingFromThemComesAlong()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Equal("Text,Popup,Link+A", Subtypes(AnnotationsOf(again, 1)));
        Assert.Equal(2, again.Pages.Count);
        Assert.DoesNotContain("Page 12", Encoding.Latin1.GetString(target.SaveRewrite()));
    }

    [Fact]
    public void ANoteKeepsItsPopupAndPointsAtTheNewPage()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var annotations = AnnotationsOf(again, 1);
        var note = annotations.First(a => again.Name(a, "Subtype") == "Text");
        var popup = annotations.First(a => again.Name(a, "Subtype") == "Popup");
        Assert.Equal(again.Pages[1].Reference, note["P"]);
        Assert.Same(popup, again.Resolve(note["Popup"]));
        Assert.Same(note, again.Resolve(popup["Parent"]));
        Assert.False(note.ContainsKey("StructParent"));
    }

    [Fact]
    public void TheSameAnnotationOnTwoCopiesOfAPageIsTwoAnnotations()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0, 0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var first = AnnotationsOf(again, 1);
        var second = AnnotationsOf(again, 2);
        Assert.Equal(first.Count, second.Count);
        Assert.DoesNotContain(first, a => second.Any(b => ReferenceEquals(a, b)));
        Assert.Equal(again.Pages[2].Reference, second.First(a => again.Name(a, "Subtype") == "Text")["P"]);
    }
}
