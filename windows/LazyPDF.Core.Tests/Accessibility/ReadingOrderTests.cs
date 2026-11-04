using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ReadingOrderTests
{
    [Fact]
    public void FollowsTheTagsOfAHandMadeFile()
    {
        using var document = TaggedFile.Open();

        Assert.Equal("# Head\nBody text\n[Figure: A picture]", ReadingOrder.Export(document));
    }

    [Fact]
    public void ChangingTheTagOrderChangesTheReadOut()
    {
        using var document = TaggedFile.Open();
        var tree = StructureTree.Read(document)!;
        tree.Move(tree.Elements.First(e => e.Type == "Figure"), tree.Roots[0], 0);

        Assert.Equal("[Figure: A picture]\n# Head\nBody text", ReadingOrder.Export(document, tree));
    }

    [Fact]
    public void AnUntaggedFileReadsAsNothing()
    {
        using var document = PdfDocument.Open(AccessKit.Report(1));

        Assert.Equal("", ReadingOrder.Export(document));
    }

    [Fact]
    public void ReportReadsHeadingParagraphsListTableAndFigureInOrder()
    {
        using var document = PdfDocument.Open(AccessKit.Report(3));
        AutoTagger.Tag(document);
        var lines = ReadingOrder.Export(document).Split('\n');

        string[] page =
        [
            "# Introduction",
            "This is the first paragraph of page 1. It has enough words to fill two lines of the body text.",
            "A second paragraph follows after a clear gap.",
            "• First item",
            "• Second item",
            "• Third item",
            "Name\tCount\tPrice",
            "Apples\t12\t3.50",
            "Pears\t7\t4.25",
            "[Figure]",
        ];
        Assert.Equal(page.Length * 3, lines.Length);
        Assert.Equal(page, lines[..page.Length]);
        Assert.Equal("# Introduction", lines[page.Length]);
        Assert.Contains("page 2.", lines[page.Length + 1]);
    }

    [Fact]
    public void FigureAltTextIsRead()
    {
        using var document = PdfDocument.Open(AccessKit.Report(1));
        AutoTagger.Tag(document);
        var tree = StructureTree.Read(document)!;
        tree.Elements.First(e => e.Type == "Figure").Alt = "Fruit sales";
        tree.Write(document);

        Assert.EndsWith("[Figure: Fruit sales]", ReadingOrder.Export(document));
    }

    [Fact]
    public void ReorderingTheTreeReordersTheOutputOfAnAutoTaggedFile()
    {
        using var document = PdfDocument.Open(AccessKit.Report(1));
        AutoTagger.Tag(document);
        var tree = StructureTree.Read(document)!;
        tree.Move(tree.Elements.First(e => e.Type == "Table"), tree.Roots[0], 0);
        tree.Write(document);

        using var again = AccessKit.Reopen(document, rewrite: true);
        Assert.StartsWith("Name\tCount\tPrice\nApples", ReadingOrder.Export(again));
    }

    [Fact]
    public void TextOfAnActualTextSpanAndInlineChildrenStaysInOneLine()
    {
        using var document = PdfDocument.Open(TaggedFile.Build(o =>
        {
            o[9] = "<</Type /StructElem /S /Document /P 8 0 R /K [10 0 R 11 0 R 12 0 R]>>";
            o[11] = "<</Type /StructElem /S /P /P 9 0 R /Pg 3 0 R /K [1 14 0 R]>>";
            o[14] = "<</Type /StructElem /S /Span /P 11 0 R /Pg 3 0 R /K 3>>";
            o[13] = "<</Nums [0 [10 0 R 11 0 R 12 0 R 14 0 R]]>>";
        }, content: TaggedFile.Content + "/Span <</MCID 3>> BDC " + AccessKit.Text(150, 670, "and more") + " EMC\n"));

        Assert.Equal("# Head\nBody text and more\n[Figure: A picture]", ReadingOrder.Export(document));
    }
}
