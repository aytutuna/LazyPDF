using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AccessReviewFixTests
{
    // A page that draws its text in a sequence of its own and a form that numbers a sequence 2 as well.
    private static byte[] PageWithForm()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R /MarkInfo <</Marked true>> /Lang (en-US)>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 612 792]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /StructParents 0 /Resources <</Font <</F1 5 0 R>> /XObject <</Fm1 10 0 R>>>>>>");
        pdf.Stream(4, "", "/P <</MCID 2>> BDC BT /F1 11 Tf 72 700 Td (Page text) Tj ET EMC /Fm1 Do\n");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 7 0 R /ParentTree 9 0 R /ParentTreeNextKey 1>>");
        pdf.Obj(7, "<</Type /StructElem /S /Document /P 6 0 R /K 8 0 R>>");
        pdf.Obj(8, "<</Type /StructElem /S /P /P 7 0 R /Pg 3 0 R /K 2>>");
        pdf.Obj(9, "<</Nums [0 [null null 8 0 R]]>>");
        pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources <</Font <</F1 5 0 R>>>>", "/Span <</MCID 2>> BDC BT /F1 11 Tf 72 650 Td (Form text) Tj ET EMC");
        return pdf.Finish();
    }

    [Fact]
    public void ASequenceOfAFormIsNotTakenForTheSequenceOfThePageWithTheSameNumber()
    {
        using var document = PdfDocument.Open(PageWithForm());

        Assert.Equal("Page text", ReadingOrder.Export(document));
    }

    [Fact]
    public void AFormSequenceMissingFromTheTreeIsLooseEvenWhenThePageHoldsThatNumber()
    {
        using var document = PdfDocument.Open(PageWithForm());

        Assert.Equal(AccessibilityStatus.Failed, AccessibilityChecker.Check(document)[AccessibilityRule.TaggedContent].Status);
    }

    [Fact]
    public void ContentWithStaleSequencesIsTaggedAndNumbersAreNotRepeated()
    {
        string content = "/P <</MCID 0>> BDC BT /F1 11 Tf 72 700 Td (Old words) Tj ET EMC\n" + AccessKit.Text(72, 500, "New words");
        using var document = PdfDocument.Open(AccessKit.Build(1, _ => content));

        var result = AutoTagger.Tag(document);

        Assert.Equal(1, result.Pages);
        using var again = AccessKit.Reopen(document, rewrite: true);
        string order = ReadingOrder.Export(again);
        Assert.Contains("Old words", order);
        Assert.Contains("New words", order);
        var numbers = AccessKit.Sequences(again, 0).Where(s => s.Mcid >= 0).Select(s => s.Mcid).ToList();
        Assert.Equal(numbers.Count, numbers.Distinct().Count());
    }

    [Fact]
    public void PagesThatCarryTheSameStaleKeyGetOwnParentTreeEntries()
    {
        using var document = PdfDocument.Open(AccessKit.Build(2, i => AccessKit.Text(72, 700, $"Page {i + 1} words") + AccessKit.Text(72, 600, "More words"), pageEntries: "/StructParents 0"));

        AutoTagger.Tag(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        var tree = StructureTree.Read(again)!;
        var keys = again.Pages.Select(p => again.Integer(p.Dictionary, "StructParents")!.Value).ToList();
        Assert.Equal(2, keys.Distinct().Count());
        for (int p = 0; p < 2; p++)
        {
            foreach (var (_, mcid) in AccessKit.Sequences(again, p).Where(s => s.Mcid >= 0))
            {
                Assert.Contains(tree.ElementFor(keys[p], mcid)!.Kids.OfType<StructContent>(), c => c.PageIndex == p && c.Mcid == mcid);
            }
        }
    }

    [Fact]
    public void AnnotationWithAStaleKeyDoesNotTakeThePageEntry()
    {
        using var document = TaggedFile.Open(objects =>
        {
            objects[14] = "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /StructParent 0 /P 3 0 R>>";
            objects[9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R 15 0 R]>>";
            objects[15] = "<</Type /StructElem /S /Link /P 9 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 14 0 R /Pg 3 0 R>>>>";
        });
        var tree = StructureTree.Read(document)!;
        tree.Write(document);

        var rebuilt = StructureTree.Read(document)!;
        long page = document.Integer(document.Pages[0].Dictionary, "StructParents")!.Value;
        long annotation = document.Integer((PdfDictionary)document.Resolve(new PdfReference(14, 0))!, "StructParent")!.Value;
        Assert.NotEqual(page, annotation);
        Assert.Equal("P", rebuilt.ElementFor(page, 1)!.Type);
    }

    [Fact]
    public void TheStreamOwnerOfAnMcrSurvivesWrite()
    {
        var file = TaggedFile.Build(objects =>
        {
            objects[11] = "<</Type /StructElem /S /P /P 9 0 R /Pg 3 0 R /K <</Type /MCR /Pg 3 0 R /MCID 0 /Stm 14 0 R /StmOwn 3 0 R>>>>";
            objects[14] = "<</Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 0>>\nstream\n\nendstream";
        });
        using var withForm = PdfDocument.Open(file);
        var tree = StructureTree.Read(withForm)!;

        tree.Write(withForm);

        var mcr = withForm.Dict((PdfDictionary)withForm.Resolve(new PdfReference(11, 0))!, "K")!;
        Assert.Equal("3 0 R", mcr["StmOwn"]?.ToString());
    }

    [Fact]
    public void ATreeThatNamesFarOffSequencesOnManyPagesIsRefusedBeforeAnythingIsAllocated()
    {
        int pages = 6;
        var bytes = AccessKit.Build(pages, i => AccessKit.Text(72, 700, "Words"), "/StructTreeRoot 40 0 R", "", pdf =>
        {
            pdf.Obj(40, "<</Type /StructTreeRoot /K 41 0 R>>");
            pdf.Obj(41, "<</Type /StructElem /S /Document /P 40 0 R /K [" + string.Join(" ", Enumerable.Range(0, pages).Select(i => $"{42 + i} 0 R")) + "]>>");
            for (int i = 0; i < pages; i++) pdf.Obj(42 + i, $"<</Type /StructElem /S /P /P 41 0 R /Pg {3 + i} 0 R /K 1000000>>");
        });
        using var document = PdfDocument.Open(bytes);
        var tree = StructureTree.Read(document)!;

        Assert.False(tree.IsTruncated);
        Assert.Throws<InvalidOperationException>(() => tree.Write(document));
    }
}
