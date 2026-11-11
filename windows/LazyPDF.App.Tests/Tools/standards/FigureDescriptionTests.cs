using System.Text;
using LazyPDF.App.Tools.Accessibility;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Tagging a picture file, finding its figure and the box it covers, and writing its description.
public sealed class FigureDescriptionTests
{
    private static byte[] PictureFile() => PdfFromPictures.Create([new byte[] { 1 }], new FakeCodec()).Bytes;

    // The figure is marked on the page and drawn by a form, the usual shape of a chart or a placed graphic.
    private static byte[] FormFigure()
    {
        var pdf = new MemoryStream();
        var offsets = new List<long>();
        void Put(string text) => pdf.Write(Encoding.Latin1.GetBytes(text));
        void Obj(string body)
        {
            offsets.Add(pdf.Position);
            Put($"{offsets.Count} 0 obj\n{body}\nendobj\n");
        }
        void Stream(string entries, string data) => Obj($"<<{entries} /Length {data.Length}>>\nstream\n{data}\nendstream");

        Put("%PDF-1.7\n");
        Obj("<</Type /Catalog /Pages 2 0 R /MarkInfo <</Marked true>> /StructTreeRoot 6 0 R>>");
        Obj("<</Type /Pages /Kids [3 0 R] /Count 1>>");
        Obj("<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources <</XObject <</Fm1 5 0 R>>>> /StructParents 0>>");
        Stream("", "/Figure <</MCID 0>> BDC /Fm1 Do EMC");
        Stream("/Type /XObject /Subtype /Form /BBox [0 0 612 792]", "0.5 g 100 100 200 150 re f");
        Obj("<</Type /StructTreeRoot /K 7 0 R /ParentTree <</Nums [0 [7 0 R]]>>>>");
        Obj("<</Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0>>");
        long xref = pdf.Position;
        Put($"xref\n0 {offsets.Count + 1}\n0000000000 65535 f \n");
        foreach (long offset in offsets) Put($"{offset:D10} 00000 n \n");
        Put($"trailer\n<</Size {offsets.Count + 1} /Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n");
        return pdf.ToArray();
    }

    [Fact]
    public void AFigureMarkedOnThePageAndDrawnByAFormStillHasItsBox()
    {
        var document = PdfDocument.Open(FormFigure());
        var figure = Assert.Single(FigureFinder.List(StructureTree.Read(document)!));

        var box = FigureFinder.Box(document, figure.Element, figure.Page);

        Assert.NotNull(box);
        Assert.InRange(box.Value.Width, 199, 201);
        Assert.InRange(box.Value.Height, 149, 151);
    }

    [Fact]
    public void ReplacementTextCountsAsADescriptionAndAFigureWithoutAPageHasNoPageNumber()
    {
        var document = PdfDocument.Open(FormFigure());
        var element = FigureFinder.List(StructureTree.Read(document)!)[0].Element;
        element.ActualText = "A chart of sales.";

        var row = new FigureRow(element, -1, 3);

        Assert.False(row.HasAlt);
        Assert.True(row.HasDescription);
        Assert.Equal("A chart of sales.", row.Summary);
        Assert.Equal("Figure 3", row.Title);
    }

    [Fact]
    public void EveryFigureIsListedHoweverManyThereAre()
    {
        var tree = StructureTree.Read(PdfDocument.Open(FormFigure()))!;
        for (int i = 0; i < 700; i++) tree.Add(tree.Roots[0], new StructElement("Figure"));

        Assert.Equal(701, FigureFinder.List(tree).Count);
    }

    [Fact]
    public void AddingTagsToAPictureMakesAFigureWithoutADescription()
    {
        var document = PdfDocument.Open(PictureFile());

        var result = AutoTagger.Tag(document);
        var figures = FigureFinder.List(StructureTree.Read(document)!);

        Assert.Equal(1, result.Figures);
        var figure = Assert.Single(figures);
        Assert.Equal(0, figure.Page);
        Assert.False(figure.HasAlt);
        Assert.Equal("No description", figure.Summary);
        Assert.Equal("Figure 1, page 1", figure.Title);
    }

    [Fact]
    public void TheFigureBoxIsWhereThePictureIsDrawnOnThePage()
    {
        var document = PdfDocument.Open(PictureFile());
        AutoTagger.Tag(document);
        var figure = FigureFinder.List(StructureTree.Read(document)!)[0];

        var box = FigureFinder.Box(document, figure.Element, figure.Page);

        Assert.NotNull(box);
        var page = new PageGeometry(document.Pages[0]);
        Assert.True(box.Value.Width > 0 && box.Value.Height > 0);
        Assert.InRange(box.Value.X, -0.5, page.Width);
        Assert.InRange(box.Value.Y, -0.5, page.Height);
        Assert.True(box.Value.X + box.Value.Width <= page.Width + 0.5);
        Assert.True(box.Value.Y + box.Value.Height <= page.Height + 0.5);
    }

    [Fact]
    public async Task ADescriptionIsSavedAsOneStepAndPassesTheFigureCheck()
    {
        using var f = new ViewModelFixture();
        string path = f.Dir.File("picture.pdf", PictureFile());
        await f.Vm.OpenAsync(path);
        var tab = f.Vm.ActiveDocument!;
        AutoTagger.Tag(tab.Document);
        Assert.True(tab.Commit("Add tags"));
        Assert.Equal(AccessibilityStatus.Failed, AccessibilityChecker.Check(tab.Document)[AccessibilityRule.FigureAlt].Status);

        var tree = StructureTree.Read(tab.Document)!;
        var figure = FigureFinder.List(tree)[0];
        AccessibilityEdits.SetAlt(tab.Document, tree, figure.Element, "  A grey square.  ");
        Assert.True(tab.Commit("Figure description"));

        var again = FigureFinder.List(StructureTree.Read(tab.Document)!)[0];
        Assert.Equal("A grey square.", again.Alt);
        Assert.Equal(AccessibilityStatus.Passed, AccessibilityChecker.Check(tab.Document)[AccessibilityRule.FigureAlt].Status);
    }

    [Fact]
    public void ASaveIsRefusedWhenTheFigureHasAnotherDescriptionThanTheListShowed()
    {
        var tree = StructureTree.Read(PdfDocument.Open(FormFigure()))!;
        tree.Add(tree.Roots[0], new StructElement("Figure"));
        var rows = FigureFinder.List(tree);
        string listed = rows[0].Alt;
        Assert.False(AccessibilityEdits.FigureChanged(rows[0].Element, listed));

        rows[0].Element.Alt = "Changed elsewhere.";

        Assert.True(AccessibilityEdits.FigureChanged(rows[0].Element, listed));
        Assert.True(AccessibilityEdits.FigureChanged(null, listed));
        Assert.False(AccessibilityEdits.FigureChanged(rows[1].Element, rows[1].Alt));
    }

    [Fact]
    public async Task AnEmptyDescriptionTakesTheOldOneAway()
    {
        using var f = new ViewModelFixture();
        await f.Vm.OpenAsync(f.Dir.File("picture.pdf", PictureFile()));
        var tab = f.Vm.ActiveDocument!;
        AutoTagger.Tag(tab.Document);
        var tree = StructureTree.Read(tab.Document)!;
        var figure = FigureFinder.List(tree)[0];
        AccessibilityEdits.SetAlt(tab.Document, tree, figure.Element, "Words");
        tab.Commit("Figure description");

        tree = StructureTree.Read(tab.Document)!;
        AccessibilityEdits.SetAlt(tab.Document, tree, FigureFinder.List(tree)[0].Element, " ");
        tab.Commit("Figure description");

        Assert.False(FigureFinder.List(StructureTree.Read(tab.Document)!)[0].HasAlt);
    }

    [Fact]
    public void AFileWithoutTagsHasNoFigures()
    {
        var document = PdfDocument.Open(Pdfs.Text());

        Assert.Null(StructureTree.Read(document));
    }
}
