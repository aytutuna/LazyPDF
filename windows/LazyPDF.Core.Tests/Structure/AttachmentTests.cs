using System.Security.Cryptography;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class AttachmentTests
{
    private static readonly DateTimeOffset Made = new(2026, 5, 6, 7, 8, 9, TimeSpan.FromHours(2));

    [Fact]
    public void AddListExtractRoundTrip()
    {
        var document = StructureFixtures.Open();
        byte[] text = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("a line of text\n", 500)));
        byte[] binary = RandomNumberGenerator.GetBytes(300);
        PdfAttachments.Add(document, "notes.txt", text, "text/plain", "Meeting notes", Made, Made.AddDays(1));
        PdfAttachments.Add(document, "blob.bin", binary);

        var reopened = StructureFixtures.Reopen(document);
        var list = PdfAttachments.List(reopened);
        Assert.Equal(["blob.bin", "notes.txt"], list.Select(a => a.Name));
        var notes = list[1];
        Assert.Equal(("notes.txt", "Meeting notes", "text/plain"), (notes.FileName, notes.Description, notes.MimeType));
        Assert.Equal(text.Length, notes.Size);
        Assert.True(notes.StoredSize < text.Length);
        Assert.Equal(Made, notes.Created);
        Assert.Equal(Made.AddDays(1), notes.Modified);
        Assert.Equal(Convert.ToHexString(MD5.HashData(text)), notes.CheckSum);
        Assert.Null(notes.PageIndex);
        Assert.Equal(text, PdfAttachments.Extract(reopened, notes));
        Assert.Equal(binary, PdfAttachments.Extract(reopened, list[0]));
        Assert.Null(list[0].MimeType);
        Assert.Null(list[0].Created);
    }

    [Fact]
    public void EmptyFile()
    {
        var document = StructureFixtures.Open();
        PdfAttachments.Add(document, "empty", []);
        var reopened = StructureFixtures.Reopen(document);
        Assert.Empty(PdfAttachments.Extract(reopened, PdfAttachments.List(reopened).Single()));
    }

    [Fact]
    public void NamesAreMadeUnique()
    {
        var document = StructureFixtures.Open();
        var one = PdfAttachments.Add(document, "a.pdf", [1]);
        var two = PdfAttachments.Add(document, "a.pdf", [2]);
        var three = PdfAttachments.Add(document, "a.pdf", [3]);
        Assert.Equal(["a.pdf", "a (2).pdf", "a (3).pdf"], new[] { one, two, three }.Select(a => a.Name));
        Assert.Equal([2], PdfAttachments.Extract(document, two));
    }

    [Fact]
    public void NonLatinNamesSurvive()
    {
        var document = StructureFixtures.Open();
        PdfAttachments.Add(document, "Журнал.txt", [1], description: "Türkçe");
        var item = PdfAttachments.List(StructureFixtures.Reopen(document)).Single();
        Assert.Equal("Журнал.txt", item.Name);
        Assert.Equal("Türkçe", item.Description);
    }

    [Fact]
    public void ManyAttachmentsMakeATree()
    {
        var document = StructureFixtures.Open();
        for (int i = 0; i < 150; i++) PdfAttachments.Add(document, $"f{i:D3}.dat", [(byte)i]);
        var reopened = StructureFixtures.Reopen(document);
        var list = PdfAttachments.List(reopened);
        Assert.Equal(150, list.Count);
        Assert.Equal([100], PdfAttachments.Extract(reopened, list[100]));
    }

    [Fact]
    public void RemoveFreesTheObjects()
    {
        var document = StructureFixtures.Open();
        var keep = PdfAttachments.Add(document, "keep", [1]);
        var drop = PdfAttachments.Add(document, "drop", [2]);
        int before = document.ObjectNumbers.Count;
        Assert.True(PdfAttachments.Remove(document, drop));
        Assert.Equal(before - 2, document.ObjectNumbers.Count);
        Assert.False(PdfAttachments.Remove(document, drop));
        var reopened = StructureFixtures.Reopen(document);
        Assert.Equal(["keep"], PdfAttachments.List(reopened).Select(a => a.Name));
        Assert.Equal([1], PdfAttachments.Extract(reopened, PdfAttachments.List(reopened)[0]));
        Assert.NotNull(keep);
    }

    [Fact]
    public void RemovingTheLastOneRemovesTheTree()
    {
        var document = StructureFixtures.Open();
        var only = PdfAttachments.Add(document, "only", [1]);
        Assert.True(PdfAttachments.Remove(document, only));
        Assert.Null(document.Dict(document.Catalog, "Names")!["EmbeddedFiles"]);
        Assert.Empty(PdfAttachments.List(StructureFixtures.Reopen(document)));
    }

    [Fact]
    public void ExtractAfterRemoveFails()
    {
        var document = StructureFixtures.Open();
        var item = PdfAttachments.Add(document, "x", [1]);
        PdfAttachments.Remove(document, item);
        Assert.Throws<InvalidOperationException>(() => PdfAttachments.Extract(document, item));
    }

    private static PdfDocument WithAnnotations() => StructureFixtures.File("", pdf =>
    {
        pdf.Stream(30, "/Type /EmbeddedFile /Subtype /application#2Fpdf /Params <</Size 5 /ModDate (D:20260102030405Z)>>", "hello");
        pdf.Obj(31, "<</Type /Filespec /F (inner.pdf) /Desc (From a note) /EF <</F 30 0 R>>>>");
        pdf.Obj(32, "<</Type /Annot /Subtype /FileAttachment /Rect [10 10 20 20] /Contents (Annotation text) /FS 31 0 R /Name /PushPin>>");
        pdf.Obj(33, "<</Type /Filespec /F (outside.pdf)>>");
        pdf.Obj(34, "<</Type /Annot /Subtype /FileAttachment /Rect [10 10 20 20] /FS 33 0 R>>");
        pdf.Obj(35, "<</Type /Annot /Subtype /Link /Rect [10 10 20 20]>>");
    }, pages: 2);

    [Fact]
    public void ListsAttachmentAnnotations()
    {
        var document = WithAnnotations();
        document.Pages[1].Dictionary["Annots"] = new PdfArray([new PdfReference(32, 0), new PdfReference(34, 0), new PdfReference(35, 0)]);
        var item = Assert.Single(PdfAttachments.List(document));
        Assert.Equal(("inner.pdf", "inner.pdf", "From a note"), (item.Name, item.FileName, item.Description));
        Assert.Equal(1, item.PageIndex);
        Assert.Equal(32, item.Annotation!.Number);
        Assert.Equal("application/pdf", item.MimeType);
        Assert.Equal(5, item.Size);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero), item.Modified);
        Assert.Equal("hello"u8.ToArray(), PdfAttachments.Extract(document, item));
    }

    [Fact]
    public void AnnotationNoteIsTheDescriptionWhenTheFileHasNone()
    {
        var document = WithAnnotations();
        ((PdfDictionary)document.Get(31)!).Remove("Desc");
        document.Pages[0].Dictionary["Annots"] = new PdfArray([new PdfReference(32, 0)]);
        Assert.Equal("Annotation text", PdfAttachments.List(document).Single().Description);
    }

    [Fact]
    public void RemovesAnAnnotationAttachment()
    {
        var document = WithAnnotations();
        document.Pages[0].Dictionary["Annots"] = new PdfArray([new PdfReference(32, 0), new PdfReference(35, 0)]);
        var item = PdfAttachments.List(document).Single();
        Assert.True(PdfAttachments.Remove(document, item));
        Assert.Null(document.Get(32));
        Assert.Null(document.Get(31));
        Assert.Null(document.Get(30));
        Assert.Single(((PdfArray)document.Pages[0].Dictionary["Annots"]!).Items);
        Assert.Empty(PdfAttachments.List(document));
    }

    [Fact]
    public void FileSpecsWithoutStreamsAreLeftOut()
    {
        var document = StructureFixtures.File("/Names <</EmbeddedFiles <</Names [(a) 33 0 R (b) 99 0 R (c) 31 0 R]>>>>", pdf =>
        {
            pdf.Obj(33, "<</Type /Filespec /F (outside.pdf)>>");
            pdf.Stream(30, "", "x");
            pdf.Obj(31, "<</F (c.txt) /EF <</F 30 0 R>>>>");
        });
        Assert.Equal(["c"], PdfAttachments.List(document).Select(a => a.Name));
    }

    [Fact]
    public void FileNameFallsBackToTheTreeKey()
    {
        var document = StructureFixtures.File("/Names <</EmbeddedFiles <</Names [(key) 31 0 R]>>>>", pdf =>
        {
            pdf.Stream(30, "", "x");
            pdf.Obj(31, "<</EF <</UF 30 0 R>>>>");
        });
        var item = PdfAttachments.List(document).Single();
        Assert.Equal(("key", "key"), (item.Name, item.FileName));
    }

    [Fact]
    public void WorksInAnEncryptedDocument()
    {
        var id = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();
        var security = PdfSecurity.Create("", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, id, new Random(5));
        var encrypted = PdfDocument.Open(StructureFixtures.Open().SaveRewrite(new PdfSaveOptions(Security: security)));
        Assert.True(encrypted.IsEncrypted);

        byte[] data = Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("secret ", 100)));
        PdfAttachments.Add(encrypted, "secret.txt", data, "text/plain", "Hidden");
        var reopened = PdfDocument.Open(encrypted.SaveIncremental());
        var item = PdfAttachments.List(reopened).Single();
        Assert.Equal("Hidden", item.Description);
        Assert.Equal(data, PdfAttachments.Extract(reopened, item));

        var rewritten = PdfDocument.Open(encrypted.SaveRewrite(new PdfSaveOptions(Security: encrypted.Security)));
        Assert.Equal(data, PdfAttachments.Extract(rewritten, PdfAttachments.List(rewritten).Single()));
    }

    [Fact]
    public void PortfolioFieldsAreRead()
    {
        var document = StructureFixtures.File("/Collection 30 0 R", pdf =>
            pdf.Obj(30, "<</Type /Collection /View /T /D (first.txt) /Schema <</Type /CollectionSchema /Size <</Subtype /N /N (Bytes) /O 3 /V false>> /Name <</Subtype /S /N (Title) /O 1 /E true>> /Odd 5>>>>"));
        var portfolio = PdfPortfolio.Read(document)!;
        Assert.Equal(("T", "first.txt"), (portfolio.View, portfolio.InitialDocument));
        Assert.Equal(["Name", "Size"], portfolio.Fields.Select(f => f.Key));
        Assert.Equal(("Title", "S", true, true), (portfolio.Fields[0].Label, portfolio.Fields[0].Type, portfolio.Fields[0].Visible, portfolio.Fields[0].Editable));
        Assert.Equal(("Bytes", "N", false), (portfolio.Fields[1].Label, portfolio.Fields[1].Type, portfolio.Fields[1].Visible));
    }

    [Fact]
    public void NoCollectionNoPortfolio()
    {
        Assert.Null(PdfPortfolio.Read(StructureFixtures.Open()));
        var bare = StructureFixtures.File("/Collection <<>>");
        Assert.Equal("D", PdfPortfolio.Read(bare)!.View);
    }
}
