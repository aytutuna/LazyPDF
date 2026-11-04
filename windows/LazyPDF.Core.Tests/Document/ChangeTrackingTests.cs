using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ChangeTrackingTests
{
    private static PdfDocument Open() => PdfDocument.Open(TestPdf.Simple(2));

    [Fact]
    public void ReadingChangesNothing()
    {
        var document = Open();
        foreach (var page in document.Pages) page.Contents();
        _ = document.Info;
        document.Get(2);
        Assert.Empty(document.ChangedObjects());
        Assert.Empty(document.DeletedObjects);
        Assert.False(document.TrailerChanged);
    }

    [Fact]
    public void ChangeInsideANestedValueIsFound()
    {
        var document = Open();
        var kids = document.Array(document.Dict(document.Catalog, "Pages"), "Kids")!;
        kids.Items.Add(new PdfReference(3, 0));
        Assert.Equal([2], document.ChangedObjects());

        document.Pages[0].Dictionary["Rotate"] = new PdfNumber(90);
        Assert.Equal([2, 3], document.ChangedObjects());
    }

    [Fact]
    public void ChangeToADirectValueOfTheCatalogIsFound()
    {
        var document = Open();
        document.Catalog["Lang"] = new PdfString(TestPdf.Latin("tr"), isHex: false);
        Assert.Equal([1], document.ChangedObjects());
    }

    [Fact]
    public void SettingTheDataOfAStreamIsAChange()
    {
        var document = Open();
        var stream = document.Resolve<PdfStream>(document.Pages[0].Dictionary["Contents"])!;
        Assert.Empty(document.ChangedObjects());
        stream.Data = TestPdf.Latin("q Q");
        Assert.Equal([stream.Number], document.ChangedObjects());
        Assert.Equal("q Q", TestPdf.Text(document.Pages[0].Contents()));
    }

    [Fact]
    public void ChangingAStreamsDictionaryIsAChange()
    {
        var document = Open();
        var stream = document.Resolve<PdfStream>(document.Pages[1].Dictionary["Contents"])!;
        stream.Dictionary["Subtype"] = new PdfName("Form");
        Assert.Equal([stream.Number], document.ChangedObjects());
    }

    [Fact]
    public void ObjectsAddedAreNewAndCountedFromTheEnd()
    {
        var document = Open();
        int next = document.NextObjectNumber;
        var reference = document.Add(new PdfDictionary());
        Assert.Equal(next, reference.Number);
        Assert.Equal(next + 1, document.NextObjectNumber);
        Assert.Equal([reference.Number], document.ChangedObjects());
        Assert.Contains(reference.Number, document.ObjectNumbers);
        Assert.NotNull(document.Resolve(reference));
    }

    [Fact]
    public void ReplacingAnObjectIsAChangeEvenIfEqual()
    {
        var document = Open();
        document.Set(3, document.Get(3)!);
        Assert.Equal([3], document.ChangedObjects());
    }

    [Fact]
    public void DeletedObjectsReadAsNullAndAreListed()
    {
        var document = Open();
        document.Delete(3);
        Assert.Null(document.Get(3));
        Assert.Null(document.Resolve(new PdfReference(3, 0)));
        Assert.Equal([3], document.DeletedObjects);
        Assert.DoesNotContain(3, document.ObjectNumbers);
        Assert.Empty(document.ChangedObjects());
        document.Delete(3);
        document.Delete(999);
        Assert.Equal([3], document.DeletedObjects);
    }

    [Fact]
    public void ObjectDeletedBeforeItWasLoadedIsStillFree()
    {
        var document = Open();
        document.Delete(4);
        Assert.Null(document.Get(4));
        Assert.Equal([4], document.DeletedObjects);
    }

    [Fact]
    public void ObjectAddedAndDeletedLeavesNoTrace()
    {
        var document = Open();
        var reference = document.Add(new PdfDictionary());
        document.Delete(reference.Number);
        Assert.Empty(document.ChangedObjects());
        Assert.Empty(document.DeletedObjects);
    }

    [Fact]
    public void TrailerChangeIsSeen()
    {
        var document = Open();
        document.Trailer["Info"] = document.Add(new PdfDictionary());
        Assert.True(document.TrailerChanged);
    }

    [Fact]
    public void EncryptedStringsAreComparedAfterDecryption()
    {
        var security = PdfSecurity.Create("", "o", PdfPermissions.All, PdfCryptStrength.Aes128, new byte[16], new Random(1));
        var pdf = new TestPdf("%PDF-1.6\n")
            .Obj(1, "<</Type /Catalog /Pages 2 0 R /Lang <" + Convert.ToHexString(security.EncryptString(1, 0, TestPdf.Latin("en"))) + ">>>")
            .Obj(2, "<</Type /Pages /Kids [] /Count 0>>")
            .Obj(3, security.Dictionary.ToString());
        var document = PdfDocument.Open(pdf.Finish("/Root 1 0 R /Encrypt 3 0 R /ID [<00000000000000000000000000000000> <00000000000000000000000000000000>]"));
        Assert.Equal("en", TestPdf.Text(((PdfString)document.Catalog["Lang"]!).Bytes));
        Assert.Empty(document.ChangedObjects());
    }

    [Fact]
    public void StartAndSizeOfTheFileAreKnown()
    {
        var file = TestPdf.Simple(1);
        var document = PdfDocument.Open(file);
        Assert.Equal(file.Length, document.Length);
        Assert.Equal(TestPdf.Text(file).LastIndexOf("xref\n0", StringComparison.Ordinal), document.StartXref);
        Assert.False(document.XrefIsStream);
        Assert.False(document.XrefRebuilt);
        Assert.Equal(5, document.NextObjectNumber);
        Assert.Equal(0, document.GenerationOf(1));
    }
}
