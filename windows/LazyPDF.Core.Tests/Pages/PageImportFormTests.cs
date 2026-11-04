using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageImportFormTests
{
    // Page 4 carries a text field, one widget of a field "grp" and a signature field; page 5 carries the other widget of "grp".
    private const string Form = "/AcroForm <</Fields [50 0 R 52 0 R 54 0 R] /DA (/Helv 0 Tf 0 g) /DR <</Font <</Helv 60 0 R>>>> /NeedAppearances true>>";

    private static PdfDocument Source() => PdfDocument.Open(PageImportTests.Source("/Annots [50 0 R 51 0 R 54 0 R]", Form, pdf => pdf
        .Obj(50, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Alice) /DA (/Helv 12 Tf 0 g) /Rect [0 0 50 20]>>")
        .Obj(51, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 30 50 50]>>")
        .Obj(52, "<</T (grp) /FT /Tx /V (G) /Kids [51 0 R 53 0 R]>>")
        .Obj(53, "<</Type /Annot /Subtype /Widget /Parent 52 0 R /Rect [0 60 50 80]>>")
        .Obj(54, "<</Type /Annot /Subtype /Widget /FT /Sig /T (sig) /V 55 0 R /Rect [0 90 50 110]>>")
        .Obj(55, "<</Type /Sig /Filter /Adobe.PPKLite /Contents <0000> /ByteRange [0 1 2 3]>>")
        .Obj(60, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"), "/Annots [53 0 R]"));

    private static List<PdfDictionary> Roots(PdfDocument document) =>
        [.. document.Array(document.Dict(document.Catalog, "AcroForm"), "Fields")!.Items.Select(f => (PdfDictionary)document.Resolve(f)!)];

    private static string Text(PdfDocument document, PdfDictionary field, string key) =>
        Encoding.Latin1.GetString(((PdfString)document.Resolve(field[key])!).Bytes);

    private static string Names(PdfDocument document) => string.Join(",", Roots(document).Select(r => Text(document, r, "T")));

    [Fact]
    public void TheFieldsOfAnImportedPageJoinTheTargetsForm()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Equal("name,grp,sig", Names(again));
        var roots = Roots(again);
        Assert.Equal("Alice", Text(again, roots[0], "V"));
        Assert.Equal("G", Text(again, roots[1], "V"));
        Assert.False(roots[2].ContainsKey("V"));
        Assert.Equal("/Helv 12 Tf 0 g", Text(again, roots[0], "DA"));
        Assert.Equal("/Helv 0 Tf 0 g", Text(again, roots[1], "DA"));
        Assert.True(again.Bool(again.Dict(again.Catalog, "AcroForm"), "NeedAppearances"));
        Assert.True(again.Dict(again.Dict(again.Dict(again.Catalog, "AcroForm"), "DR"), "Font")!.ContainsKey("Helv"));
    }

    [Fact]
    public void AFieldKeepsOnlyTheWidgetsThatCameAcross()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var group = Roots(again)[1];
        var kids = again.Array(group, "Kids")!.Items;
        Assert.Single(kids);
        var widget = (PdfDictionary)again.Resolve(kids[0])!;
        Assert.Same(group, again.Resolve(widget["Parent"]));
        Assert.Contains(kids[0], again.Array(again.Pages[1].Dictionary, "Annots")!.Items);
    }

    [Fact]
    public void WidgetsOfOneFieldOnSeveralImportedPagesShareTheField()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0, 1], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Equal("name,grp,sig", Names(again));
        Assert.Equal(2, again.Array(Roots(again)[1], "Kids")!.Items.Count);
    }

    [Fact]
    public void ASignatureFieldKeepsItsLookAndLosesTheSignature()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.DoesNotContain("Adobe.PPKLite", Encoding.Latin1.GetString(target.SaveRewrite()));
        var widget = Roots(again)[2];
        Assert.Equal("Widget", again.Name(widget, "Subtype"));
        Assert.True(widget.ContainsKey("Rect"));
    }

    [Fact]
    public void ANameThatIsTakenGetsASuffixSoTheValuesStaySeparate()
    {
        var target = PageTestFiles.Open(1);
        var source = Source();
        PageOperations.ImportPages(target, source, [0], 1);
        PageOperations.ImportPages(target, source, [0], 1);
        PageOperations.ImportPages(target, source, [0, 0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Equal("name,grp,sig,name_2,grp_2,sig_2,name_3,grp_3,sig_3,name_4,grp_4,sig_4", Names(again));
        Assert.Equal(12, Roots(again).Count);
        Assert.Equal(5, again.Pages.Count);
    }

    [Fact]
    public void AFormTheTargetHadIsKeptAsItWas()
    {
        var target = PageTestFiles.Open(1, "/AcroForm <</Fields [20 0 R] /DR <</Font <</Helv 21 0 R>>>>>>", add: pdf => pdf
            .Obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (Bob) /Rect [0 0 10 10]>>")
            .Obj(21, "<</Type /Font /Subtype /Type1 /BaseFont /Times-Roman>>"));
        PageOperations.ImportPages(target, Source(), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Equal("name,name_2,grp,sig", Names(again));
        Assert.Equal("Bob", Text(again, Roots(again)[0], "V"));
        Assert.Equal("Alice", Text(again, Roots(again)[1], "V"));
        var fonts = again.Dict(again.Dict(again.Dict(again.Catalog, "AcroForm"), "DR"), "Font")!;
        Assert.Equal("Times-Roman", again.Name((PdfDictionary)again.Resolve(fonts["Helv"])!, "BaseFont"));
    }

    [Fact]
    public void ADuplicatedPageGetsFieldsOfItsOwn()
    {
        var target = Source();
        PageOperations.Duplicate(target, [0]);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Equal("name,grp,sig,name_2,grp_2,sig_2", Names(again));
        var firstWidgets = again.Array(again.Pages[0].Dictionary, "Annots")!.Items;
        var secondWidgets = again.Array(again.Pages[1].Dictionary, "Annots")!.Items;
        Assert.Empty(firstWidgets.Intersect(secondWidgets));
        Assert.Equal(2, again.Array(Roots(again)[1], "Kids")!.Items.Count);
        Assert.Single(again.Array(Roots(again)[4], "Kids")!.Items);
    }

    [Fact]
    public void TheImportedFormReadsBackAndOpensInPdfPig()
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, Source(), [0, 1], 1);
        Assert.Equal(3, PageTestFiles.Reopen(target).Count);
    }
}
