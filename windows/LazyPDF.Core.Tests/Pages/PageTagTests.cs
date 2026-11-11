using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageTagTests
{
    // Four pages with a heading each, a table across pages 2 and 3 and a link annotation on page 2.
    private static PdfDocument Tagged()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 12 0 R /MarkInfo <</Marked true>> /Lang (en)>>");
        pdf.Obj(2, "<</Type /Pages /Kids [4 0 R 5 0 R 6 0 R 7 0 R] /Count 4 /MediaBox [0 0 200 300]>>");
        pdf.Obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        for (int i = 0; i < 4; i++)
        {
            string annots = i == 1 ? "/Annots [22 0 R]" : "";
            pdf.Obj(4 + i, $"<</Type /Page /Parent 2 0 R /Contents {8 + i} 0 R /Resources <</Font <</F1 3 0 R>>>> /StructParents {i} {annots}>>");
            string row = i is 1 or 2 ? $"/TR <</MCID 1>> BDC BT /F1 12 Tf 20 50 Td (Row {i + 1}) Tj ET EMC" : "";
            pdf.Stream(8 + i, "", $"/H1 <</MCID 0>> BDC BT /F1 12 Tf 20 100 Td (Page {i + 1}) Tj ET EMC {row}");
        }
        pdf.Obj(12, "<</Type /StructTreeRoot /K 13 0 R /ParentTree 30 0 R /ParentTreeNextKey 6 /RoleMap <</Head /H1>>>>");
        pdf.Obj(13, "<</Type /StructElem /S /Document /P 12 0 R /K [14 0 R 15 0 R 18 0 R 16 0 R 17 0 R 21 0 R]>>");
        for (int i = 0; i < 4; i++) pdf.Obj(14 + i, $"<</Type /StructElem /S /H1 /P 13 0 R /Pg {4 + i} 0 R /K 0 /Alt (Heading {i + 1})>>");
        pdf.Obj(18, "<</Type /StructElem /S /Table /P 13 0 R /K [19 0 R 20 0 R] /Alt (TABLEALT)>>");
        pdf.Obj(19, "<</Type /StructElem /S /TR /P 18 0 R /Pg 5 0 R /K 1>>");
        pdf.Obj(20, "<</Type /StructElem /S /TR /P 18 0 R /Pg 6 0 R /K 1>>");
        pdf.Obj(21, "<</Type /StructElem /S /Link /P 13 0 R /Pg 5 0 R /K <</Type /OBJR /Pg 5 0 R /Obj 22 0 R>>>>");
        pdf.Obj(22, "<</Type /Annot /Subtype /Link /Rect [10 10 50 30] /Border [0 0 0] /StructParent 5 /A <</S /URI /URI (http://example.com)>>>>");
        pdf.Obj(30, "<</Nums [0 [14 0 R] 1 [15 0 R 19 0 R] 2 [16 0 R 20 0 R] 3 [17 0 R] 5 21 0 R]>>");
        return PdfDocument.Open(pdf.Finish());
    }

    private static string Roles(PdfDocument document, PdfObject? node)
    {
        if (document.Resolve(node) is not PdfDictionary element) return "";
        var kids = document.Resolve(element["K"]);
        var below = kids is PdfArray array ? array.Items : kids is null ? [] : [element["K"]!];
        return string.Join(" ", new[] { document.Name(element, "S") ?? "" }.Concat(below.Select(k => Roles(document, k))).Where(s => s != ""));
    }

    private static PdfDictionary Root(PdfDocument document) => document.Dict(document.Catalog, "StructTreeRoot")!;

    private static List<long> Keys(PdfDocument document) =>
        [.. PdfNumberTree.Read(document, Root(document)["ParentTree"]).Select(e => e.Key)];

    private static PdfDocument Saved(PdfDocument part, out string text)
    {
        byte[] bytes = part.SaveRewrite();
        text = Encoding.Latin1.GetString(bytes);
        var again = PdfDocument.Open(bytes);
        Assert.Empty(again.Repairs);
        return again;
    }

    private static bool Marked(PdfDocument document) =>
        document.Dict(document.Catalog, "MarkInfo") is { } mark && document.Resolve(mark["Marked"]) is PdfBoolean { Value: true };

    [Fact]
    public void ExtractKeepsTheElementsOfThePageTaken()
    {
        var part = Saved(PageAssembly.Extract(Tagged(), [1]), out string text);
        Assert.Equal("Document H1 Table TR Link", Roles(part, Root(part)));
        Assert.Equal([1L, 5L], Keys(part));
        var page = part.Pages[0].Dictionary;
        Assert.Equal(1, part.Integer(page, "StructParents"));
        var annotation = (PdfReference)part.Array(page, "Annots")!.Items[0];
        Assert.Equal(5, part.Integer((PdfDictionary)part.Resolve(annotation)!, "StructParent"));
        var link = (PdfDictionary)part.Resolve(PdfNumberTree.Read(part, Root(part)["ParentTree"]).Single(e => e.Key == 5).Value)!;
        Assert.Equal(annotation.Number, ((PdfReference)part.Dict(link, "K")!["Obj"]!).Number);
        Assert.Contains("Heading 2", text);
        Assert.DoesNotContain("Heading 1", text);
        Assert.DoesNotContain("Heading 3", text);
        Assert.DoesNotContain("TABLEALT", text);
        Assert.DoesNotContain("Row 3", text);
        Assert.DoesNotContain("Page 3", text);
        Assert.Equal(AccessibilityStatus.Passed, AccessibilityChecker.Check(part)[AccessibilityRule.TaggedContent].Status);
        Assert.True(Marked(part));
    }

    [Fact]
    public void ExtractLeavesOutAnElementWhoseContentIsAllOnOtherPages()
    {
        var part = Saved(PageAssembly.Extract(Tagged(), [0]), out string text);
        Assert.Equal("Document H1", Roles(part, Root(part)));
        Assert.Equal([0L], Keys(part));
        Assert.DoesNotContain("TABLEALT", text);
        Assert.Equal(AccessibilityStatus.Passed, AccessibilityChecker.Check(part)[AccessibilityRule.TaggedContent].Status);
    }

    [Fact]
    public void MergeGivesEachSourceKeysOfItsOwn()
    {
        var merged = Saved(PageAssembly.Merge([new MergeSource(Tagged()), new MergeSource(Tagged())]), out _);
        Assert.Equal([0L, 1, 2, 3, 5, 6, 7, 8, 9, 11], Keys(merged));
        Assert.Equal([0L, 1, 2, 3, 6, 7, 8, 9], merged.Pages.Select(p => merged.Integer(p.Dictionary, "StructParents")!.Value));
        var root = Root(merged);
        Assert.Equal(12, merged.Integer(root, "ParentTreeNextKey"));
        Assert.Equal("Document H1 H1 Table TR TR H1 H1 Link Document H1 H1 Table TR TR H1 H1 Link", Roles(merged, root));
        foreach (var kid in merged.Array(root, "K")!.Items) Assert.Equal(((PdfReference)merged.Catalog["StructTreeRoot"]!).Number, ((PdfReference)((PdfDictionary)merged.Resolve(kid)!)["P"]!).Number);
        Assert.Equal(AccessibilityStatus.Passed, AccessibilityChecker.Check(merged)[AccessibilityRule.TaggedContent].Status);
        Assert.True(Marked(merged));
    }

    [Fact]
    public void MergeWithAnUntaggedSourceIsNotMarked()
    {
        var merged = Saved(PageAssembly.Merge([new MergeSource(Tagged(), [1]), new MergeSource(PageTestFiles.Open(2))]), out _);
        Assert.Equal([1L, 5L], Keys(merged));
        Assert.False(Marked(merged));
        Assert.False(merged.Pages[1].Dictionary.ContainsKey("StructParents"));
    }
}
