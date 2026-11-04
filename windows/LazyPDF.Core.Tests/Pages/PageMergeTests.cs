using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageMergeTests
{
    private static PdfDocument Doc(int count, string catalogExtra = "") => PageTestFiles.Open(count, catalogExtra);

    [Fact]
    public void SourcesFollowEachOtherWithTheirRanges()
    {
        var merged = PageAssembly.Merge([new MergeSource(Doc(3)), new MergeSource(Doc(4), PageRange.Parse("2-3, 1", 4).Pages), new MergeSource(Doc(2), [])]);
        Assert.Equal([1, 2, 3, 2, 3, 1], PageTestFiles.Order(merged));
        Assert.Equal(["Page 1", "Page 2", "Page 3", "Page 2", "Page 3", "Page 1"], PageTestFiles.Reopen(merged));
    }

    [Fact]
    public void TheMergeIsAFreshDocumentWithOneBalancedTree()
    {
        var merged = PageAssembly.Merge([new MergeSource(Doc(40)), new MergeSource(Doc(40))]);
        var again = PdfDocument.Open(merged.SaveRewrite());
        Assert.Empty(again.Repairs);
        Assert.Equal(80, again.Pages.Count);
        Assert.True(again.Array(again.Dict(again.Catalog, "Pages"), "Kids")!.Items.Count <= 32);
    }

    [Fact]
    public void AFontSharedByAllPagesOfASourceIsCopiedOnce()
    {
        var merged = PageAssembly.Merge([new MergeSource(Doc(10)), new MergeSource(Doc(10))]);
        var again = PdfDocument.Open(merged.SaveRewrite());
        int fonts = again.ObjectNumbers.Count(n => again.Get(n) is PdfDictionary d && again.Name(d, "Type") == "Font");
        Assert.Equal(2, fonts);
    }

    [Fact]
    public void ADocumentListedTwiceIsCopiedOnce()
    {
        var source = Doc(10);
        var merged = PageAssembly.Merge([new MergeSource(source, [0]), new MergeSource(source, [9])]);
        var again = PdfDocument.Open(merged.SaveRewrite());
        Assert.Equal([1, 10], PageTestFiles.Order(again));
        Assert.Equal(1, again.ObjectNumbers.Count(n => again.Get(n) is PdfDictionary d && again.Name(d, "Type") == "Font"));
    }

    [Fact]
    public void TheFirstSourcesInfoIsKept()
    {
        var first = PdfDocument.Open(PageTestFiles.Make(1, trailerExtra: "/Info 20 0 R", add: pdf => pdf.Obj(20, "<</Title (First) /Author (Someone)>>")));
        var merged = PageAssembly.Merge([new MergeSource(first), new MergeSource(Doc(1))]);
        var again = PdfDocument.Open(merged.SaveRewrite());
        Assert.Equal("First", Encoding.Latin1.GetString(((PdfString)again.Info!["Title"]!).Bytes));
    }

    [Fact]
    public void FormFieldsOfTwoFilesWithTheSameNamesStayApart()
    {
        PdfDocument Form(string value) => PdfDocument.Open(PageTestFiles.Make(1, "/AcroForm <</Fields [20 0 R]>>", i => "/Annots [20 0 R]",
            add: pdf => pdf.Obj(20, $"<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V ({value}) /Rect [0 0 10 10]>>")));
        var merged = PageAssembly.Merge([new MergeSource(Form("one")), new MergeSource(Form("two"))]);
        var again = PdfDocument.Open(merged.SaveRewrite());
        var fields = again.Array(again.Dict(again.Catalog, "AcroForm"), "Fields")!.Items.Select(f => (PdfDictionary)again.Resolve(f)!).ToList();
        Assert.Equal(["name", "name_2"], fields.Select(f => Encoding.Latin1.GetString(((PdfString)f["T"]!).Bytes)));
        Assert.Equal(["one", "two"], fields.Select(f => Encoding.Latin1.GetString(((PdfString)f["V"]!).Bytes)));
    }

    [Fact]
    public void NothingToMergeIsRefused()
    {
        Assert.Throws<ArgumentException>(() => PageAssembly.Merge([]));
        Assert.Throws<ArgumentException>(() => PageAssembly.Merge([new MergeSource(Doc(2), [])]));
        Assert.Throws<ArgumentOutOfRangeException>(() => PageAssembly.Merge([new MergeSource(Doc(2), [5])]));
    }

    [Fact]
    public void SourcesThatAreEncryptedMerge()
    {
        byte[] id = new byte[16];
        var locked = PdfSecurity.Create("", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, id, new Random(3));
        var encrypted = PdfDocument.Open(PdfDocument.Open(PageTestFiles.Make(2)).SaveRewrite(new PdfSaveOptions(false, locked)));
        var merged = PageAssembly.Merge([new MergeSource(encrypted), new MergeSource(Doc(1))]);
        Assert.Equal(["Page 1", "Page 2", "Page 1"], PageTestFiles.Reopen(merged));
    }

    [Fact]
    public void AMergeGoesThroughASessionAsOneStep()
    {
        var merged = PageAssembly.Merge([new MergeSource(Doc(2)), new MergeSource(Doc(2))]);
        var session = PdfEditSession.Open(merged.SaveRewrite());
        PageOperations.Delete(session.Document, [0]);
        Assert.True(session.Commit("Delete"));
        Assert.Equal([2, 1, 2], PageTestFiles.Order(PdfDocument.Open(session.Current.ToArray())));
        Assert.True(session.Undo());
        Assert.Equal(4, session.Document.Pages.Count);
    }
}
