using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SaveRewriteTests
{
    public static IEnumerable<object[]> Kinds => SaveFixtures.Kinds.Select(k => new object[] { k });

    private static string Text(byte[] bytes) => Encoding.Latin1.GetString(bytes);

    private static void AssertSameContent(PdfDocument expected, PdfDocument actual)
    {
        Assert.Equal(expected.Pages.Count, actual.Pages.Count);
        for (int i = 0; i < expected.Pages.Count; i++) Assert.Equal(expected.Pages[i].Contents(), actual.Pages[i].Contents());
        Assert.Equal(SaveFixtures.Title(expected), SaveFixtures.Title(actual));
    }

    [Theory, MemberData(nameof(Kinds))]
    public void RewriteOfEveryLayoutReadsTheSame(string kind)
    {
        var original = PdfDocument.Open(SaveFixtures.Make(kind));
        foreach (bool packed in new[] { false, true })
        {
            byte[] rewritten = original.SaveRewrite(new PdfSaveOptions(packed, original.Security));
            var reopened = PdfDocument.Open(rewritten);
            Assert.Empty(reopened.Repairs);
            AssertSameContent(original, reopened);
            Assert.Equal(original.IsEncrypted, reopened.IsEncrypted);
            Assert.Equal(packed, Text(rewritten).Contains("/Type /XRef"));
        }
    }

    [Theory, MemberData(nameof(Kinds))]
    public void PdfPigReadsTheRewrite(string kind)
    {
        var original = PdfDocument.Open(SaveFixtures.Make(kind));
        foreach (bool packed in new[] { false, true })
        {
            using var pig = UglyToad.PdfPig.PdfDocument.Open(original.SaveRewrite(new PdfSaveOptions(packed, original.Security)));
            Assert.Equal(2, pig.NumberOfPages);
            Assert.Equal("Original title", pig.Information.Title);
            Assert.Equal("Page two", pig.GetPage(2).Text);
        }
    }

    [Fact]
    public void OnlyReachableObjectsAreKeptAndTheyAreNumberedFromOne()
    {
        var pdf = new TestPdf();
        pdf.Obj(10, "<</Type /Catalog /Pages 20 0 R>>");
        pdf.Obj(20, "<</Type /Pages /Kids [30 0 R] /Count 1 /MediaBox [0 0 100 100]>>");
        pdf.Obj(30, "<</Type /Page /Parent 20 0 R /Contents 40 0 R>>");
        pdf.Stream(40, "", "q Q");
        pdf.Obj(50, "<</Orphan (never reached)>>");
        pdf.Obj(60, "<</Gone 99 0 R /Cycle 60 0 R>>");
        var original = PdfDocument.Open(pdf.Finish("/Root 10 0 R"));
        byte[] rewritten = original.SaveRewrite();

        Assert.DoesNotContain("never reached", Text(rewritten));
        var reopened = PdfDocument.Open(rewritten);
        Assert.Equal([1, 2, 3, 4], reopened.ObjectNumbers);
        Assert.Single(reopened.Pages);
        Assert.Equal("q Q", Text(reopened.Pages[0].Contents()));
        Assert.Equal(1, ((PdfReference)reopened.Trailer["Root"]!).Number);
    }

    [Fact]
    public void GenerationsGoBackToZeroAndReferencesToNothingAreDropped()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Dangling 77 0 R /List [78 0 R 1]>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 100]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        var reopened = PdfDocument.Open(PdfDocument.Open(pdf.Finish()).SaveRewrite());
        Assert.False(reopened.Catalog.ContainsKey("Dangling"));
        var list = reopened.Array(reopened.Catalog, "List")!;
        Assert.IsType<PdfNull>(list.Items[0]);
        Assert.All(reopened.ObjectNumbers, n => Assert.Equal(0, reopened.GenerationOf(n)));
    }

    [Fact]
    public void RewriteKeepsTheFirstIdAndMakesASecond()
    {
        var original = PdfDocument.Open(SaveFixtures.Table());
        var reopened = PdfDocument.Open(original.SaveRewrite());
        Assert.Equal(2, reopened.Id.Count);
        Assert.Equal(original.Id[0], reopened.Id[0]);
        Assert.NotEqual(original.Id[0], reopened.Id[1]);

        var given = PdfDocument.Open(original.SaveRewrite(new PdfSaveOptions(DocumentId: SaveFixtures.FileId[..8])));
        Assert.Equal(SaveFixtures.FileId[..8], given.Id[0]);
    }

    [Fact]
    public void ObjectStreamsPackThePlainObjectsOnly()
    {
        var original = PdfDocument.Open(SaveFixtures.Table());
        byte[] rewritten = original.SaveRewrite(new PdfSaveOptions(UseObjectStreams: true));
        var reopened = PdfDocument.Open(rewritten);

        Assert.StartsWith("%PDF-1.5", Text(rewritten));
        int catalog = ((PdfReference)reopened.Trailer["Root"]!).Number;
        int info = ((PdfReference)reopened.Trailer["Info"]!).Number;
        Assert.Equal(PdfDocument.EntryKind.InUse, reopened.Entries[catalog].Kind);
        Assert.Equal(PdfDocument.EntryKind.Compressed, reopened.Entries[info].Kind);
        Assert.Equal(PdfDocument.EntryKind.Compressed, reopened.Entries[reopened.Pages[0].Reference.Number].Kind);
        Assert.Equal(PdfDocument.EntryKind.InUse, reopened.Entries[((PdfReference)reopened.Pages[0].Dictionary["Contents"]!).Number].Kind);
        Assert.True(reopened.XrefIsStream);
        Assert.True(rewritten.Length < SaveFixtures.Table().Length * 2);
        AssertSameContent(original, reopened);
    }

    [Fact]
    public void ManyObjectsGoIntoSeveralObjectStreams()
    {
        var pdf = new TestPdf("%PDF-1.4\n");
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 100]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        var items = Enumerable.Range(0, 250).Select(i => $"<</N {i}>>").ToList();
        for (int i = 0; i < items.Count; i++) pdf.Obj(10 + i, items[i]);
        pdf.Obj(300, $"<</Type /Info /Refs [{string.Join(' ', Enumerable.Range(0, 250).Select(i => $"{10 + i} 0 R"))}]>>");
        var original = PdfDocument.Open(pdf.Finish("/Root 1 0 R /Info 300 0 R"));
        var reopened = PdfDocument.Open(original.SaveRewrite(new PdfSaveOptions(true)));

        Assert.Empty(reopened.Repairs);
        var refs = reopened.Array(reopened.Info, "Refs")!;
        Assert.Equal(250, refs.Items.Count);
        for (int i = 0; i < 250; i++) Assert.Equal(i, reopened.Integer((PdfDictionary)reopened.Resolve(refs.Items[i])!, "N"));
        Assert.Equal(3, reopened.ObjectNumbers.Count(n => reopened.Get(n) is PdfStream s && reopened.Name(s.Dictionary, "Type") == "ObjStm"));
    }

    [Fact]
    public void SignatureDictionaryStaysOutOfObjectStreams()
    {
        var original = PdfDocument.Open(SaveFixtures.Table());
        var signature = new PdfDictionary();
        signature.Add("Type", new PdfName("Sig"));
        signature.Add("ByteRange", new PdfArray([new PdfNumber(0), new PdfNumber(9)]));
        signature.Add("Contents", new PdfString([1, 2, 3], isHex: true));
        var reference = original.Add(signature);
        original.Catalog["Sig"] = reference;
        var reopened = PdfDocument.Open(original.SaveRewrite(new PdfSaveOptions(true)));
        int number = ((PdfReference)reopened.Catalog["Sig"]!).Number;
        Assert.Equal(PdfDocument.EntryKind.InUse, reopened.Entries[number].Kind);
    }

    [Fact]
    public void StreamsAreRecompressedOnlyWhereItPaysAndNeverCodecData()
    {
        byte[] flat = Encoding.Latin1.GetBytes(string.Concat(Enumerable.Repeat("0 0 m 10 10 l S\n", 200)));
        byte[] jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 0xFF, 0xD9];
        byte[] lzw = PdfFilterEncoders.Lzw(flat);
        byte[] hex = PdfFilterEncoders.AsciiHex(flat);
        byte[] flate = TestPdf.Deflate(flat);
        byte[] predicted = TestPdf.Deflate(flat);
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /A 4 0 R /B 5 0 R /C 6 0 R /D 7 0 R /E 8 0 R /F 9 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Stream(4, "", flat);
        pdf.Stream(5, "/Filter /DCTDecode /Subtype /Image", jpeg);
        pdf.Stream(6, "/Filter /LZWDecode", lzw);
        pdf.Stream(7, "/Filter /ASCIIHexDecode", hex);
        pdf.Stream(8, "/Filter /FlateDecode", flate);
        pdf.Stream(9, "/Filter /FlateDecode /DecodeParms <</Predictor 12 /Columns 4>>", predicted);
        var original = PdfDocument.Open(pdf.Finish());
        var reopened = PdfDocument.Open(original.SaveRewrite());

        PdfStream Stream(string key) => (PdfStream)reopened.Resolve(reopened.Catalog[key])!;
        string Filter(string key) => Stream(key).Dictionary["Filter"]?.ToString() ?? "";

        Assert.Equal("/FlateDecode", Filter("A"));
        Assert.True(reopened.RawData(Stream("A")).Length < flat.Length / 4);
        Assert.Equal("/DCTDecode", Filter("B"));
        Assert.Equal(jpeg, reopened.RawData(Stream("B")));
        Assert.Equal("/FlateDecode", Filter("C"));
        Assert.Equal("/FlateDecode", Filter("D"));
        Assert.Equal(flat, reopened.Data(Stream("A")));
        Assert.Equal(flat, reopened.Data(Stream("C")));
        Assert.Equal(flat, reopened.Data(Stream("D")));
        Assert.Equal(flate, reopened.RawData(Stream("E")));
        Assert.Equal(predicted, reopened.RawData(Stream("F")));
        Assert.True(reopened.Dict(Stream("F").Dictionary, "DecodeParms") is not null);
    }

    [Fact]
    public void StreamThatDoesNotDecodeIsCopiedAsItIs()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Bad 4 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        pdf.Stream(4, "/Filter /ASCIIHexDecode", "zz not hex at all, not even close", length: 1000);
        var original = PdfDocument.Open(pdf.Finish());
        var reopened = PdfDocument.Open(original.SaveRewrite());
        var stream = (PdfStream)reopened.Get(((PdfReference)reopened.Catalog["Bad"]!).Number)!;
        Assert.Equal("zz not hex at all, not even close", Text(reopened.RawData(stream)));
    }

    [Fact]
    public void EncryptionCanBeAddedRemovedAndKept()
    {
        var plain = PdfDocument.Open(SaveFixtures.Table());
        foreach (var strength in new[] { PdfCryptStrength.Aes128, PdfCryptStrength.Aes256 })
        {
            var security = PdfSecurity.Create("open", "owner", PdfPermissions.All, strength, SaveFixtures.FileId, new Random(3));
            byte[] encrypted = plain.SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: SaveFixtures.FileId));
            Assert.DoesNotContain("Original title", Text(encrypted));
            Assert.Throws<PdfReadException>(() => PdfDocument.Open(encrypted));
            var opened = PdfDocument.Open(encrypted, "open");
            AssertSameContent(plain, opened);
            Assert.StartsWith(strength == PdfCryptStrength.Aes128 ? "%PDF-1.6" : "%PDF-1.7", Text(encrypted));

            byte[] kept = opened.SaveRewrite(new PdfSaveOptions(UseObjectStreams: true, Security: opened.Security));
            AssertSameContent(plain, PdfDocument.Open(kept, "open"));
            Assert.DoesNotContain("Original title", Text(kept));

            byte[] removed = opened.SaveRewrite();
            var open = PdfDocument.Open(removed);
            Assert.False(open.IsEncrypted);
            AssertSameContent(plain, open);
        }
    }

    [Fact]
    public void KeptOlderHandlerKeepsTheFirstId()
    {
        var original = PdfDocument.Open(SaveFixtures.Make("aes128"));
        var reopened = PdfDocument.Open(original.SaveRewrite(new PdfSaveOptions(Security: original.Security)));
        Assert.Equal(SaveFixtures.FileId, reopened.Id[0]);
        Assert.Equal("Original title", SaveFixtures.Title(reopened));
    }

    [Fact]
    public void PageEditsAreInTheRewrite()
    {
        var document = PdfDocument.Open(SaveFixtures.Make("objects"));
        SaveFixtures.Edit(document);
        var reopened = PdfDocument.Open(document.SaveRewrite());
        Assert.Equal("New title", SaveFixtures.Title(reopened));
        Assert.Contains("Changed", Text(reopened.Pages[1].Contents()));
        Assert.Equal("Added note", Text(((PdfString)reopened.Dict(reopened.Catalog, "Extra")!["Note"]!).Bytes));
    }

    [Fact]
    public void DamagedFileIsRewrittenFromWhatWasRepaired()
    {
        byte[] broken = TestPdf.Replace(SaveFixtures.Table(), "startxref", "startxxxxx");
        var document = PdfDocument.Open(broken);
        Assert.NotEmpty(document.Repairs);
        var reopened = PdfDocument.Open(document.SaveRewrite());
        Assert.Empty(reopened.Repairs);
        AssertSameContent(document, reopened);
    }

    [Fact]
    public void DirectInfoAndCatalogAreWrittenAsObjects()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 10 10]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        var original = PdfDocument.Open(pdf.Finish("/Root 1 0 R /Info <</Title (Direct)>>"));
        var reopened = PdfDocument.Open(original.SaveRewrite());
        Assert.Equal("Direct", SaveFixtures.Title(reopened));
        Assert.IsType<PdfReference>(reopened.Trailer["Info"]);
    }
}
