using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SaveIncrementalTests
{
    public static IEnumerable<object[]> Kinds => SaveFixtures.Kinds.Select(k => new object[] { k });

    private static string Text(byte[] bytes) => Encoding.Latin1.GetString(bytes);

    [Theory, MemberData(nameof(Kinds))]
    public void OriginalBytesStayAndTheChangeIsThere(string kind)
    {
        byte[] original = SaveFixtures.Make(kind);
        var document = PdfDocument.Open(original);
        SaveFixtures.Edit(document);
        byte[] saved = document.SaveIncremental();

        Assert.True(saved.Length > original.Length);
        Assert.True(saved.AsSpan(0, original.Length).SequenceEqual(original));

        var reopened = PdfDocument.Open(saved);
        Assert.Empty(reopened.Repairs);
        Assert.Equal("New title", SaveFixtures.Title(reopened));
        Assert.Equal("Someone", Text(((PdfString)reopened.Info!["Author"]!).Bytes));
        Assert.Equal(2, reopened.Pages.Count);
        Assert.Equal(SaveFixtures.PageOne, Text(reopened.Pages[0].Contents()));
        Assert.Contains("Changed", Text(reopened.Pages[1].Contents()));
        var extra = reopened.Dict(reopened.Catalog, "Extra");
        Assert.Equal("Added note", Text(((PdfString)extra!["Note"]!).Bytes));
        Assert.Equal(kind.StartsWith("aes"), reopened.IsEncrypted);
    }

    [Theory, MemberData(nameof(Kinds))]
    public void PdfPigReadsTheUpdate(string kind)
    {
        var document = PdfDocument.Open(SaveFixtures.Make(kind));
        SaveFixtures.Edit(document);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveIncremental());
        Assert.Equal(2, pig.NumberOfPages);
        Assert.Equal("New title", pig.Information.Title);
        Assert.Equal("Page one", pig.GetPage(1).Text);
        Assert.Equal("Changed", pig.GetPage(2).Text);
    }

    [Fact]
    public void NothingChangedAddsNothing()
    {
        byte[] original = SaveFixtures.Table();
        var document = PdfDocument.Open(original);
        _ = document.Pages[0].Contents();
        Assert.Equal(original, document.SaveIncremental());
    }

    [Fact]
    public void OnlyWhatChangedIsWritten()
    {
        byte[] original = SaveFixtures.Table();
        var document = PdfDocument.Open(original);
        document.Info!["Title"] = new PdfString(Encoding.Latin1.GetBytes("Other"), isHex: false);
        string update = Text(document.SaveIncremental()[original.Length..]);

        Assert.Contains("7 0 obj", update);
        Assert.DoesNotContain("1 0 obj", update);
        Assert.DoesNotContain("5 0 obj", update);
        Assert.Contains("xref\n7 1\n", update);
        Assert.Contains($"/Prev {document.StartXref}", update);
        Assert.Contains("/Size 8", update);
        Assert.Contains("/Root 1 0 R", update);
        Assert.Contains("/Info 7 0 R", update);
    }

    [Theory]
    [InlineData("table", false)]
    [InlineData("hybrid", false)]
    [InlineData("stream", true)]
    [InlineData("objects", true)]
    public void SectionIsOfTheKindTheFileEndsWith(string kind, bool stream)
    {
        byte[] original = SaveFixtures.Make(kind);
        var document = PdfDocument.Open(original);
        SaveFixtures.Edit(document);
        byte[] saved = document.SaveIncremental();
        string update = Text(saved[original.Length..]);

        Assert.Equal(stream, update.Contains("/Type /XRef"));
        Assert.Equal(!stream, update.Contains("\nxref\n"));
        Assert.DoesNotContain("XRefStm", update);
        Assert.EndsWith("%%EOF\n", update);
        int at = update.LastIndexOf("startxref\n", StringComparison.Ordinal);
        long start = long.Parse(update[(at + 10)..].Split('\n')[0]);
        string section = Text(saved)[(int)start..];
        if (stream) Assert.Matches(@"^\d+ 0 obj\n<</Type /XRef", section);
        else Assert.StartsWith("xref\n", section);
    }

    [Fact]
    public void HybridFileKeepsItsObjectStreamObjectsReadable()
    {
        byte[] original = SaveFixtures.Make("hybrid");
        var document = PdfDocument.Open(original);
        Assert.Equal(PdfDocument.EntryKind.Compressed, document.Entries[3].Kind);
        document.Info!["Title"] = new PdfString(Encoding.Latin1.GetBytes("Hybrid"), isHex: false);
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Equal(2, reopened.Pages.Count);
        Assert.Equal(SaveFixtures.PageOne, Text(reopened.Pages[0].Contents()));
        Assert.Equal("Hybrid", SaveFixtures.Title(reopened));
    }

    [Fact]
    public void ObjectFromAnObjectStreamIsWrittenAsAPlainObject()
    {
        byte[] original = SaveFixtures.Make("objects");
        var document = PdfDocument.Open(original);
        Assert.Equal(PdfDocument.EntryKind.Compressed, document.Entries[document.Pages[0].Reference.Number].Kind);
        document.Pages[0].Dictionary["Rotate"] = new PdfNumber(90);
        byte[] saved = document.SaveIncremental();

        string update = Text(saved[original.Length..]);
        Assert.Contains($"{document.Pages[0].Reference.Number} 0 obj\n<<", update);
        Assert.DoesNotContain("ObjStm", update);
        var reopened = PdfDocument.Open(saved);
        Assert.Equal(PdfDocument.EntryKind.InUse, reopened.Entries[document.Pages[0].Reference.Number].Kind);
        Assert.Equal(90, reopened.Pages[0].Rotate);
        Assert.Equal(0, reopened.Pages[1].Rotate);
    }

    [Theory]
    [InlineData("table")]
    [InlineData("stream")]
    [InlineData("aes256")]
    public void DeletedObjectIsFreed(string kind)
    {
        var document = PdfDocument.Open(SaveFixtures.Make(kind));
        document.Delete(6);
        document.Pages[1].Dictionary.Remove("Contents");
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Null(reopened.Get(6));
        Assert.DoesNotContain(6, reopened.ObjectNumbers);
        Assert.Equal(1, reopened.GenerationOf(6));
        Assert.Equal(2, reopened.Pages.Count);
        Assert.Empty(reopened.Pages[1].Contents());
    }

    [Fact]
    public void FirstIdIsKeptAndTheSecondIsNew()
    {
        var document = PdfDocument.Open(SaveFixtures.Table());
        document.Info!["Title"] = new PdfString([65], isHex: false);
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Equal(2, reopened.Id.Count);
        Assert.Equal(SaveFixtures.FileId, reopened.Id[0]);
        Assert.NotEqual(SaveFixtures.FileId, reopened.Id[1]);
    }

    [Fact]
    public void FileWithoutIdGetsOne()
    {
        var document = PdfDocument.Open(TestPdf.Simple());
        document.Pages[0].Dictionary["Rotate"] = new PdfNumber(180);
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Equal(2, reopened.Id.Count);
        Assert.Equal(16, reopened.Id[0].Length);
    }

    [Fact]
    public void UpdatesCanFollowUpdates()
    {
        byte[] first = SaveFixtures.Table();
        var document = PdfDocument.Open(first);
        document.Info!["Title"] = new PdfString([49], isHex: false);
        byte[] second = document.SaveIncremental();
        document = PdfDocument.Open(second);
        document.Info!["Title"] = new PdfString([50], isHex: false);
        document.Pages[0].Dictionary["Rotate"] = new PdfNumber(270);
        byte[] third = document.SaveIncremental();

        Assert.True(third.AsSpan(0, second.Length).SequenceEqual(second));
        var reopened = PdfDocument.Open(third);
        Assert.Equal("2", SaveFixtures.Title(reopened));
        Assert.Equal(270, reopened.Pages[0].Rotate);
        Assert.Equal(3, PdfVersion.Find(reopened).Count);
    }

    [Theory]
    [InlineData("aes128")]
    [InlineData("aes256")]
    [InlineData("aes256objects")]
    public void EncryptedUpdateIsEncryptedAgain(string kind)
    {
        byte[] original = SaveFixtures.Make(kind);
        Assert.DoesNotContain("Original title", Text(original));
        var document = PdfDocument.Open(original);
        SaveFixtures.Edit(document, "Plain text title");
        byte[] saved = document.SaveIncremental();
        string update = Text(saved[original.Length..]);

        Assert.DoesNotContain("Plain text title", update);
        Assert.DoesNotContain("Added note", update);
        Assert.DoesNotContain("Changed", update);
        Assert.Contains("/Encrypt", update);
        var reopened = PdfDocument.Open(saved);
        Assert.Equal("Plain text title", SaveFixtures.Title(reopened));
        Assert.Contains("Changed", Text(reopened.Pages[1].Contents()));
        // What was not touched still reads through the older section.
        Assert.Equal(SaveFixtures.PageOne, Text(reopened.Pages[0].Contents()));
    }

    [Fact]
    public void SignatureContentsAreNotEncrypted()
    {
        var document = PdfDocument.Open(SaveFixtures.Make("aes128"));
        var signature = new PdfDictionary();
        signature.Add("Type", new PdfName("Sig"));
        signature.Add("ByteRange", new PdfArray([new PdfNumber(0), new PdfNumber(1), new PdfNumber(2), new PdfNumber(3)]));
        signature.Add("Contents", new PdfString([1, 2, 3, 4, 5], isHex: true));
        signature.Add("Reason", new PdfString(Encoding.Latin1.GetBytes("Approved"), isHex: false));
        var reference = document.Add(signature);
        var reopened = PdfDocument.Open(document.SaveIncremental());
        var read = (PdfDictionary)reopened.Get(reference.Number)!;
        Assert.Equal(new byte[] { 1, 2, 3, 4, 5 }, ((PdfString)read["Contents"]!).Bytes);
        Assert.Equal("Approved", Text(((PdfString)read["Reason"]!).Bytes));
    }

    [Fact]
    public void EncryptDictionaryInAnObjectIsNotEncrypted()
    {
        byte[] original = SaveFixtures.Make("aes256");
        var document = PdfDocument.Open(original);
        Assert.NotEqual(0, document.EncryptNumber);
        var encrypt = (PdfDictionary)document.Get(document.EncryptNumber)!;
        encrypt["Extra"] = new PdfName("Marker");
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Equal("Marker", reopened.Name((PdfDictionary)reopened.Get(reopened.EncryptNumber)!, "Extra"));
        Assert.Equal("Original title", SaveFixtures.Title(reopened));
    }

    [Fact]
    public void FileWithABrokenTableGetsAFullSection()
    {
        byte[] broken = TestPdf.Replace(SaveFixtures.Table(), "startxref", "startxxxxx");
        var document = PdfDocument.Open(broken);
        Assert.True(document.XrefRebuilt);
        document.Info!["Title"] = new PdfString([66], isHex: false);
        byte[] saved = document.SaveIncremental();
        Assert.True(saved.AsSpan(0, broken.Length).SequenceEqual(broken));

        var reopened = PdfDocument.Open(saved);
        Assert.False(reopened.XrefRebuilt);
        Assert.Empty(reopened.Repairs);
        Assert.Equal("B", SaveFixtures.Title(reopened));
        Assert.Equal(2, reopened.Pages.Count);
        Assert.Equal(SaveFixtures.PageTwo, Text(reopened.Pages[1].Contents()));
    }

    [Fact]
    public void RebuiltFileWithObjectStreamsGetsAStreamSection()
    {
        byte[] original = SaveFixtures.Make("objects");
        byte[] broken = TestPdf.Replace(original, "startxref", "startxxxxx");
        var document = PdfDocument.Open(broken);
        Assert.True(document.XrefRebuilt);
        document.Info!["Title"] = new PdfString([67], isHex: false);
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.False(reopened.XrefRebuilt);
        Assert.Equal("C", SaveFixtures.Title(reopened));
        Assert.Equal(2, reopened.Pages.Count);
        Assert.Equal(SaveFixtures.PageOne, Text(reopened.Pages[0].Contents()));
    }

    [Fact]
    public void FileThatDoesNotEndInALineBreakStillGetsAnUpdateOnItsOwnLine()
    {
        byte[] original = SaveFixtures.Table();
        byte[] trimmed = original[..^1];
        Assert.Equal((byte)'F', trimmed[^1]);
        var document = PdfDocument.Open(trimmed);
        document.Info!["Title"] = new PdfString([68], isHex: false);
        byte[] saved = document.SaveIncremental();
        Assert.Equal((byte)'\n', saved[trimmed.Length]);
        Assert.Equal("D", SaveFixtures.Title(PdfDocument.Open(saved)));
    }

    [Fact]
    public void ChangedStreamKeepsItsOtherDataAndGetsALength()
    {
        var document = PdfDocument.Open(SaveFixtures.Table());
        var stream = document.Resolve<PdfStream>(document.Pages[0].Dictionary["Contents"])!;
        stream.Dictionary["Subtype"] = new PdfName("Custom");
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Empty(reopened.Repairs);
        var read = reopened.Resolve<PdfStream>(reopened.Pages[0].Dictionary["Contents"])!;
        Assert.Equal("Custom", reopened.Name(read.Dictionary, "Subtype"));
        Assert.Equal(SaveFixtures.PageOne, Text(reopened.Data(read)));
    }

    [Fact]
    public void StringsWithAwkwardBytesSurvive()
    {
        var document = PdfDocument.Open(SaveFixtures.Table());
        byte[] awkward = [0, 13, 10, (byte)'(', (byte)')', (byte)'\\', 200, 255, (byte)'a'];
        document.Info!["Author"] = new PdfString(awkward, isHex: false);
        document.Info["Keywords"] = new PdfString(awkward, isHex: true);
        document.Info["Odd#Name"] = new PdfName("a b/c#dé");
        var info = PdfDocument.Open(document.SaveIncremental()).Info!;
        Assert.Equal(awkward, ((PdfString)info["Author"]!).Bytes);
        Assert.Equal(awkward, ((PdfString)info["Keywords"]!).Bytes);
        Assert.Equal("a b/c#dé", ((PdfName)info["Odd#Name"]!).Value);
    }

    [Fact]
    public void BytesBeforeTheHeaderAreDroppedAndOffsetsCountFromTheHeader()
    {
        byte[] original = [.. Encoding.ASCII.GetBytes("junk\n"), .. SaveFixtures.Table()];
        var document = PdfDocument.Open(original);
        document.Info!["Title"] = new PdfString([69], isHex: false);
        byte[] saved = document.SaveIncremental();
        Assert.StartsWith("%PDF-", Text(saved));
        Assert.Equal("E", SaveFixtures.Title(PdfDocument.Open(saved)));
    }
}
