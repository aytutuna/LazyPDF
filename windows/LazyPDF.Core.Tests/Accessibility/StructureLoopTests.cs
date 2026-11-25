using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StructureLoopTests
{
    [Fact]
    public void An_array_of_kids_that_contains_itself_is_read_without_overflowing_the_stack()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 7 0 R>>");
        pdf.Obj(7, "[7 0 R]");
        using var document = PdfDocument.Open(pdf.Finish());

        var tree = StructureTree.Read(document);

        Assert.NotNull(tree);
        Assert.True(tree.IsTruncated);
    }

    // Each object holds arrays nested as deep as the lexer allows and ends in a reference to the next, so only the count of levels bounds the stack.
    [Fact]
    public void Arrays_nested_inside_each_object_and_chained_across_objects_do_not_overflow_the_stack()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 10 0 R>>");
        for (int n = 10; n < 40; n++) pdf.Obj(n, new string('[', 190) + $"{n + 1} 0 R" + new string(']', 190));
        using var document = PdfDocument.Open(pdf.Finish());

        var tree = StructureTree.Read(document);

        Assert.NotNull(tree);
        Assert.True(tree.IsTruncated);
    }

    [Fact]
    public void Empty_arrays_count_against_the_node_limit()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /StructTreeRoot 6 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Obj(6, "<</Type /StructTreeRoot /K 7 0 R>>");
        pdf.Obj(7, "[" + string.Concat(Enumerable.Repeat("[]", 1_000_001)) + "]");
        using var document = PdfDocument.Open(pdf.Finish());

        var tree = StructureTree.Read(document);

        Assert.NotNull(tree);
        Assert.True(tree.IsTruncated);
    }
}
