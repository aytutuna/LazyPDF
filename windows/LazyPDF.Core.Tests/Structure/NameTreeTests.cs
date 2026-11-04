using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class NameTreeTests
{
    private static KeyValuePair<string, PdfObject> Entry(string key, long value) => new(key, new PdfNumber(value));

    [Fact]
    public void SmallTreeIsOneSortedLeaf()
    {
        var document = StructureFixtures.Open(1);
        var root = PdfNameTree.Write(document, null, [Entry("b", 2), Entry("a", 1), Entry("c", 3), Entry("a", 9)]);
        Assert.NotNull(root["Names"]);
        Assert.Null(root["Kids"]);
        var read = PdfNameTree.Read(document, root);
        Assert.Equal(["a", "b", "c"], read.Select(e => e.Key));
        Assert.Equal(9, ((PdfNumber)read[0].Value).Value);
    }

    [Fact]
    public void LargeTreeIsSplitWithLimits()
    {
        var document = StructureFixtures.Open(1);
        var entries = Enumerable.Range(0, 5000).Select(i => Entry($"n{i:D5}", i)).ToList();
        var root = PdfNameTree.Write(document, null, entries);
        var kids = Assert.IsType<PdfArray>(root["Kids"]);
        Assert.True(kids.Items.Count <= 64);
        var leaf = Assert.IsType<PdfDictionary>(document.Resolve(kids.Items[0]));
        Assert.NotNull(leaf["Limits"]);

        var read = PdfNameTree.Read(document, root);
        Assert.Equal(5000, read.Count);
        Assert.Equal(entries.Select(e => e.Key), read.Select(e => e.Key));
    }

    [Fact]
    public void LargeTreeSurvivesSavingAndPdfPig()
    {
        var document = StructureFixtures.Open(1);
        var root = PdfNameTree.Write(document, null, Enumerable.Range(0, 300).Select(i => Entry($"n{i:D4}", i)));
        PdfNames.Ensure(document)["Dests"] = document.Add(root);
        var reopened = StructureFixtures.Reopen(document);
        var tree = reopened.Dict(reopened.Dict(reopened.Catalog, "Names"), "Dests");
        Assert.Equal(300, PdfNameTree.Read(reopened, tree).Count);
    }

    [Fact]
    public void RewritingFreesOldNodes()
    {
        var document = StructureFixtures.Open(1);
        var root = PdfNameTree.Write(document, null, Enumerable.Range(0, 200).Select(i => Entry($"n{i:D4}", i)));
        var oldKid = (PdfReference)((PdfArray)root["Kids"]!).Items[0];
        PdfNameTree.Write(document, root, [Entry("only", 1)]);
        Assert.Null(document.Get(oldKid.Number));
        Assert.Null(root["Kids"]);
        Assert.Single(PdfNameTree.Read(document, root));
    }

    [Fact]
    public void EmptyTreeIsValid()
    {
        var document = StructureFixtures.Open(1);
        var root = PdfNameTree.Write(document, null, []);
        Assert.Empty(PdfNameTree.Read(document, root));
        Assert.IsType<PdfArray>(root["Names"]);
    }

    [Fact]
    public void KeysKeepTheirBytes()
    {
        var document = StructureFixtures.Open(1);
        string odd = Encoding.Latin1.GetString([0xFE, 0xFF, 0x00, 0x41, 0x80]);
        var root = PdfNameTree.Write(document, null, [Entry(odd, 1)]);
        Assert.Equal(odd, PdfNameTree.Read(document, root)[0].Key);
        Assert.Equal("caf\u00E9", PdfNameTree.TextOf(PdfNameTree.KeyOf("caf\u00E9")));
        Assert.Equal("A\u0416", PdfNameTree.TextOf(PdfNameTree.KeyOf("A\u0416")));
    }

    [Fact]
    public void ReadsHandWrittenNestedTreeInAnyOrderOfKeys()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Obj(20, "<</Kids [21 0 R 22 0 R] /Limits [(a) (z)]>>");
        pdf.Obj(21, "<</Names [(a) 1 (b) 2] /Limits [(a) (b)]>>");
        pdf.Obj(22, "<</Kids [23 0 R]>>");
        pdf.Obj(23, "<</Names [(y) 3 (z) 4]>>");
        var document = PdfDocument.Open(pdf.Finish());
        var read = PdfNameTree.Read(document, new PdfReference(20, 0));
        Assert.Equal(["a", "b", "y", "z"], read.Select(e => e.Key));
    }

    [Fact]
    public void LoopsAndJunkAreCutOff()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Obj(20, "<</Kids [20 0 R 21 0 R 99 0 R 5 (x) null] /Names [(a) 1 (odd)]>>");
        pdf.Obj(21, "<</Names [1 2 (k) 3 (m)]>>");
        var document = PdfDocument.Open(pdf.Finish());
        var read = PdfNameTree.Read(document, new PdfReference(20, 0));
        Assert.Equal(["a", "k"], read.Select(e => e.Key));
    }

    [Fact]
    public void DeepChainIsCutOff()
    {
        var pdf = TestPdf.WithPages(1);
        for (int i = 0; i < 100; i++) pdf.Obj(20 + i, $"<</Kids [{21 + i} 0 R] /Names [(k{i}) {i}]>>");
        var document = PdfDocument.Open(pdf.Finish());
        var read = PdfNameTree.Read(document, new PdfReference(20, 0));
        Assert.InRange(read.Count, 1, 40);
    }

    [Fact]
    public void NumberTreeRoundTrips()
    {
        var document = StructureFixtures.Open(1);
        var entries = new[] { 7L, 0, 300, 12 }.Select(n => new KeyValuePair<long, PdfObject>(n, new PdfNumber(n * 2)));
        var root = PdfNumberTree.Write(document, null, entries);
        var read = PdfNumberTree.Read(document, root);
        Assert.Equal([0, 7, 12, 300], read.Select(e => e.Key));
        Assert.Equal(600, ((PdfNumber)read[3].Value).Value);
    }

    [Fact]
    public void LargeNumberTreeIsSplit()
    {
        var document = StructureFixtures.Open(1);
        var root = PdfNumberTree.Write(document, null, Enumerable.Range(0, 1000).Select(i => new KeyValuePair<long, PdfObject>(i, new PdfNumber(i))));
        Assert.NotNull(root["Kids"]);
        Assert.Equal(1000, PdfNumberTree.Read(document, root).Count);
    }

    [Fact]
    public void NumberTreeIgnoresNonIntegerKeys()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Obj(20, "<</Nums [0 (a) 1.5 (b) 2 (c) (x) (d)]>>");
        var document = PdfDocument.Open(pdf.Finish());
        Assert.Equal([0L, 2L], PdfNumberTree.Read(document, new PdfReference(20, 0)).Select(e => e.Key));
    }
}
