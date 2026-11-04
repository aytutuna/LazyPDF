using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageLabelShiftTests
{
    // Pages 1 and 2 are numbered i, ii; pages 3 to 5 are numbered 5, 6, 7.
    private const string Labels = "/PageLabels <</Nums [0 <</S /r>> 2 <</S /D /St 5>>]>>";

    private static List<(long Start, string Style, long? St)> Ranges(PdfDocument document)
    {
        var nums = document.Array(document.Dict(document.Catalog, "PageLabels"), "Nums")!.Items;
        var ranges = new List<(long, string, long?)>();
        for (int i = 0; i < nums.Count; i += 2)
        {
            var label = (PdfDictionary)document.Resolve(nums[i + 1])!;
            ranges.Add((((PdfNumber)nums[i]).Integer!.Value, document.Name(label, "S")!, document.Integer(label, "St")));
        }
        return ranges;
    }

    [Fact]
    public void RangesMoveUpWithTheirFirstPage()
    {
        var document = PageTestFiles.Open(5, Labels);
        PageOperations.Delete(document, [0]);
        Assert.Equal([(0L, "r", (long?)2), (1L, "D", 5L)], Ranges(document));
    }

    [Fact]
    public void ARangeThatLosesItsFirstPagesStartsFurtherOn()
    {
        var document = PageTestFiles.Open(5, Labels);
        PageOperations.Delete(document, [2, 3]);
        Assert.Equal([(0L, "r", (long?)null), (2L, "D", 7L)], Ranges(document));
    }

    [Fact]
    public void ARangeWithNoPageLeftIsDropped()
    {
        var document = PageTestFiles.Open(5, Labels);
        PageOperations.Delete(document, [0, 1]);
        Assert.Equal([(0L, "D", (long?)5L)], Ranges(document));
    }

    [Fact]
    public void APageInTheMiddleOfARangeJustShortensIt()
    {
        var document = PageTestFiles.Open(5, Labels);
        PageOperations.Delete(document, [3]);
        Assert.Equal([(0L, "r", (long?)null), (2L, "D", 5L)], Ranges(document));
    }

    [Fact]
    public void ALabelTreeWithKidsIsReadAndWrittenFlat()
    {
        var tree = "/PageLabels <</Kids [<</Limits [0 1] /Nums [0 <</S /r>>]>> <</Limits [2 4] /Nums [2 <</S /D>>]>>]>>";
        var document = PageTestFiles.Open(5, tree);
        PageOperations.Delete(document, [0]);
        var root = document.Dict(document.Catalog, "PageLabels")!;
        Assert.False(root.ContainsKey("Kids"));
        Assert.Equal([(0L, "r", (long?)2), (1L, "D", null)], Ranges(document));
    }

    [Fact]
    public void LabelsFollowAnInsertedPageAndStayWhereTheyAreWhenPagesMove()
    {
        var document = PageTestFiles.Open(5, Labels);
        PageOperations.Reorder(document, [4, 3, 2, 1, 0]);
        Assert.Equal([(0L, "r", (long?)null), (2L, "D", 5L)], Ranges(document));
        PageOperations.InsertBlank(document, 2, 100, 100);
        Assert.Equal([(0L, "r", (long?)null), (3L, "D", 5L)], Ranges(document));
    }

    [Fact]
    public void ADocumentWithoutLabelsGetsNone()
    {
        var document = PageTestFiles.Open(3);
        PageOperations.Delete(document, [0]);
        PageOperations.InsertBlank(document, 0, 100, 100);
        Assert.Null(document.Catalog["PageLabels"]);
    }
}
