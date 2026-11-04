using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What points at a page when it is deleted: bookmarks, links, named destinations, the open action.
public class PageDeleteReferenceTests
{
    // Pages are objects 4 to 7 (indexes 0 to 3).
    private const int Outline = 12;

    private static PdfDocument Open(string catalogExtra, Func<int, string>? pageExtra = null, Action<TestPdf>? add = null) =>
        PageTestFiles.Open(4, catalogExtra, pageExtra, add: pdf =>
        {
            pdf.Obj(Outline, $"<</Type /Outlines /First {Outline + 1} 0 R /Last {Outline + 4} 0 R /Count 4>>");
            pdf.Obj(Outline + 1, $"<</Title (One) /Parent {Outline} 0 R /Next {Outline + 2} 0 R /Dest [4 0 R /Fit]>>");
            pdf.Obj(Outline + 2, $"<</Title (Two) /Parent {Outline} 0 R /Prev {Outline + 1} 0 R /Next {Outline + 3} 0 R /Dest [5 0 R /XYZ 0 0 0] /First {Outline + 5} 0 R /Last {Outline + 5} 0 R /Count 1>>");
            pdf.Obj(Outline + 3, $"<</Title (Three) /Parent {Outline} 0 R /Prev {Outline + 2} 0 R /Next {Outline + 4} 0 R /A <</S /GoTo /D [7 0 R /Fit]>>>>");
            pdf.Obj(Outline + 4, $"<</Title (Four) /Parent {Outline} 0 R /Prev {Outline + 3} 0 R /Dest (c)>>");
            pdf.Obj(Outline + 5, $"<</Title (Child) /Parent {Outline + 2} 0 R /Dest [6 0 R /Fit]>>");
            add?.Invoke(pdf);
        });

    private const string Names = "/Dests <</a [5 0 R /Fit] /b [6 0 R /Fit]>> /Names <</Dests <</Names [(c) [5 0 R /Fit] (d) [6 0 R /Fit] (e) <</D [4 0 R /Fit]>>]>>>>";

    private static PdfDictionary Item(PdfDocument document, int offset) => (PdfDictionary)document.Get(Outline + offset)!;

    [Fact]
    public void BookmarksKeepTheirPlaceAndLoseTheDestinationOfADeletedPage()
    {
        var document = Open($"/Outlines {Outline} 0 R {Names}");
        PageOperations.Delete(document, [1, 3]);
        Assert.True(Item(document, 1).ContainsKey("Dest"));
        Assert.False(Item(document, 2).ContainsKey("Dest"));
        Assert.False(Item(document, 3).ContainsKey("A"));
        Assert.False(Item(document, 4).ContainsKey("Dest"));
        Assert.True(Item(document, 5).ContainsKey("Dest"));
        Assert.All(new[] { 1, 2, 3, 4, 5 }, n => Assert.True(Item(document, n).ContainsKey("Title")));
        Assert.Equal(new PdfReference(Outline + 4, 0), Item(document, 3)["Next"]);
    }

    [Fact]
    public void NamedDestinationsOfDeletedPagesAreRemoved()
    {
        var document = Open($"/Outlines {Outline} 0 R {Names}");
        PageOperations.Delete(document, [1]);
        var old = document.Dict(document.Catalog, "Dests")!;
        Assert.False(old.ContainsKey("a"));
        Assert.True(old.ContainsKey("b"));
        var names = document.Array(document.Dict(document.Dict(document.Catalog, "Names"), "Dests"), "Names")!.Items;
        Assert.Equal(["d", "e"], names.Where((_, i) => i % 2 == 0).Select(n => Encoding.Latin1.GetString(((PdfString)n).Bytes)));
    }

    [Fact]
    public void ADestinationInANameTreeWithKidsIsFoundAndRemoved()
    {
        string tree = "/Names <</Dests <</Kids [<</Limits [(a) (c)] /Names [(a) [4 0 R /Fit] (c) [5 0 R /Fit]]>> <</Limits [(d) (e)] /Names [(e) [5 0 R /Fit]]>>]>>>>";
        var document = Open($"/Outlines {Outline} 0 R {tree}");
        PageOperations.Delete(document, [1]);
        var root = document.Dict(document.Dict(document.Catalog, "Names"), "Dests")!;
        var kids = document.Array(root, "Kids")!.Items.Select(k => (PdfDictionary)document.Resolve(k)!).ToList();
        Assert.Single(kids);
        Assert.Equal(2, document.Array(kids[0], "Names")!.Items.Count);
    }

    [Fact]
    public void LinksOnOtherPagesLoseADestinationThatIsGone()
    {
        int link = PageTestFiles.Free(4) + 10;
        var document = Open("", pageExtra: i => i == 0 ? $"/Annots [{link} 0 R {link + 1} 0 R]" : "", add: pdf =>
        {
            pdf.Obj(link, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [6 0 R /Fit]>>");
            pdf.Obj(link + 1, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [5 0 R /Fit]>>>>");
        });
        PageOperations.Delete(document, [2]);
        var gone = (PdfDictionary)document.Get(link)!;
        var kept = (PdfDictionary)document.Get(link + 1)!;
        Assert.False(gone.ContainsKey("Dest"));
        Assert.True(kept.ContainsKey("A"));
    }

    [Fact]
    public void ALinkToTheNextPageStillGoesThere()
    {
        int link = PageTestFiles.Free(4) + 10;
        var document = Open("", pageExtra: i => i == 0 ? $"/Annots [{link} 0 R]" : "", add: pdf =>
            pdf.Obj(link, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [6 0 R /Fit]>>"));
        PageOperations.Delete(document, [1]);
        var again = PdfDocument.Open(document.SaveRewrite());
        var annotation = (PdfDictionary)again.Resolve(again.Array(again.Pages[0].Dictionary, "Annots")!.Items[0])!;
        Assert.Equal(again.Pages[1].Reference, PageDestinations.PageOf(again, annotation["Dest"]));
    }

    [Fact]
    public void TheOpenActionOfADeletedPageGoes()
    {
        var gone = Open("/OpenAction [5 0 R /Fit]");
        PageOperations.Delete(gone, [1]);
        Assert.False(gone.Catalog.ContainsKey("OpenAction"));
        var action = Open("/OpenAction <</S /GoTo /D [6 0 R /Fit]>>");
        PageOperations.Delete(action, [1]);
        Assert.True(action.Catalog.ContainsKey("OpenAction"));
    }

    [Fact]
    public void ATaggedDocumentLosesItsStructureWhenATaggedPageGoes()
    {
        string tags = "/StructTreeRoot 40 0 R /MarkInfo <</Marked true>>";
        Func<int, string> parents = i => $"/StructParents {i}";
        var document = Open(tags, parents, pdf => pdf.Obj(40, "<</Type /StructTreeRoot>>"));
        PageOperations.Delete(document, [1]);
        Assert.False(document.Catalog.ContainsKey("StructTreeRoot"));
        Assert.False(document.Catalog.ContainsKey("MarkInfo"));
        Assert.All(document.Pages, p => Assert.False(p.Dictionary.ContainsKey("StructParents")));
    }

    [Fact]
    public void TheStructureStaysWhenNoTaggedPageGoes()
    {
        var document = Open("/StructTreeRoot 40 0 R", i => i == 0 ? "" : $"/StructParents {i}", pdf => pdf.Obj(40, "<</Type /StructTreeRoot>>"));
        PageOperations.Delete(document, [0]);
        Assert.True(document.Catalog.ContainsKey("StructTreeRoot"));
        Assert.All(document.Pages, p => Assert.True(p.Dictionary.ContainsKey("StructParents")));
    }

    [Fact]
    public void WhatIsLeftReadsBackWithoutRepairs()
    {
        var document = Open($"/Outlines {Outline} 0 R {Names} /OpenAction [5 0 R /Fit]");
        PageOperations.Delete(document, [1, 2]);
        var again = PdfDocument.Open(document.SaveRewrite());
        Assert.Empty(again.Repairs);
        Assert.Equal(2, again.Pages.Count);
    }
}
