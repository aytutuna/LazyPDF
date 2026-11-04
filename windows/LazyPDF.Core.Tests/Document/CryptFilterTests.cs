using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class CryptFilterTests
{
    private static readonly byte[] FileId = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();

    private static PdfSecurity Handler(PdfCryptStrength strength = PdfCryptStrength.Aes128, string owner = "owner") =>
        PdfSecurity.Create("", owner, PdfPermissions.All, strength, FileId, new Random(7));

    /// <summary>A one-page AES-128 file whose content stream (object 6) has the given dictionary entries and is stored by <paramref name="store"/>.</summary>
    private static (byte[] File, PdfSecurity Security) Encrypted(string entries, Func<PdfSecurity, PdfDictionary, byte[]> store, string? filterObject = null)
    {
        var security = Handler();
        var pdf = new TestPdf("%PDF-1.6\n");
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /MediaBox [0 0 50 50]>>");
        if (filterObject is not null) pdf.Obj(9, filterObject);
        pdf.Stream(6, entries, store(security, FilterFixtures.Dict($"<< {entries} >>")));
        pdf.Obj(8, security.Dictionary.ToString());
        string id = Convert.ToHexString(FileId);
        return (pdf.Finish($"/Root 1 0 R /Encrypt 8 0 R /ID [<{id}> <{id}>]"), security);
    }

    private static string Contents(byte[] file) => TestPdf.Text(PdfDocument.Open(file).Pages[0].Contents());

    [Fact]
    public void StreamWithANamedCryptFilterIsDecodedAfterDecryption()
    {
        var (file, _) = Encrypted("/Filter [/Crypt /FlateDecode] /DecodeParms [<</Name /StdCF>> null]",
            (s, d) => s.EncryptStream(6, 0, TestPdf.Deflate(TestPdf.Latin("0 0 m")), d));
        var document = PdfDocument.Open(file);
        Assert.Equal("0 0 m", TestPdf.Text(document.Data((PdfStream)document.Get(6)!)));
        Assert.Equal("0 0 m", TestPdf.Text(document.Pages[0].Contents()));
    }

    [Fact]
    public void IndirectFilterPicksTheSameCipherOnWritingAsOnReading()
    {
        var (file, _) = Encrypted("/Filter 9 0 R /DecodeParms [<</Name /Identity>>]",
            (s, d) => TestPdf.Latin("HELLO"), filterObject: "[/Crypt]");
        var document = PdfDocument.Open(file);
        Assert.Equal("HELLO", TestPdf.Text(document.Pages[0].Contents()));
        Assert.Equal("HELLO", Contents(document.SaveRewrite(new PdfSaveOptions(Security: document.Security))));

        ((PdfStream)document.Get(6)!).Dictionary["Touched"] = new PdfNumber(1);
        Assert.Equal("HELLO", Contents(document.SaveIncremental()));
    }

    [Fact]
    public void RewriteWithAnotherHandlerDropsTheCryptFilter()
    {
        var (file, _) = Encrypted("/Filter /Crypt /DecodeParms <</Name /StdCF>>",
            (s, d) => s.EncryptStream(6, 0, TestPdf.Latin("q Q"), d));
        var document = PdfDocument.Open(file);

        byte[] plain = document.SaveRewrite();
        Assert.DoesNotContain("Crypt", TestPdf.Text(plain));
        var reopened = PdfDocument.Open(plain);
        Assert.Equal("q Q", TestPdf.Text(reopened.Data((PdfStream)reopened.Resolve(reopened.Pages[0].Dictionary["Contents"])!)));

        byte[] again = document.SaveRewrite(new PdfSaveOptions(Security: Handler(PdfCryptStrength.Aes256, "other")));
        Assert.Equal("q Q", Contents(again));
    }

    [Fact]
    public void EmbeddedFilesUseTheCryptFilterNamedByEff()
    {
        var original = Handler();
        var dictionary = original.Dictionary;
        dictionary["StmF"] = new PdfName("Identity");
        dictionary["StrF"] = new PdfName("Identity");
        dictionary["EFF"] = new PdfName("StdCF");
        var reader = PdfSecurity.Open(dictionary, FileId, "")!;

        byte[] stored = original.EncryptStream(5, 0, TestPdf.Latin("attachment"), new PdfDictionary());
        var attachment = FilterFixtures.Dict("<< /Type /EmbeddedFile >>");
        Assert.Equal("attachment", TestPdf.Text(reader.DecryptStream(5, 0, stored, attachment)));
        Assert.Equal(stored, reader.DecryptStream(5, 0, stored, new PdfDictionary()));
    }

    [Fact]
    public void Aes128WithAShortKeyIsRefusedWhenTheHandlerOpens()
    {
        var dictionary = SyntheticEncryption.Legacy(4, 3, 40, "", "o", cfm: "AESV2").Dictionary;
        var e = Assert.Throws<PdfReadException>(() => PdfSecurity.Open(dictionary, SyntheticEncryption.Id, ""));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void UpdatesKeepTheFirstIdThatTheKeyWasMadeFrom()
    {
        var built = SyntheticEncryption.Legacy(2, 3, 128, "", "owner");
        string id = Convert.ToHexString(SyntheticEncryption.Id);
        var pdf = TestPdf.WithPages(1);
        pdf.Obj(9, $"[<{id}> <{id}>]");
        byte[] file = pdf.Finish($"/Root 1 0 R /ID 9 0 R /Encrypt {built.Dictionary}");

        var document = PdfDocument.Open(file);
        Assert.True(document.IsEncrypted);
        document.Catalog["Touched"] = new PdfNumber(1);
        Assert.True(PdfDocument.Open(document.SaveIncremental()).IsEncrypted);
        Assert.True(PdfDocument.Open(document.SaveRewrite(new PdfSaveOptions(Security: document.Security))).IsEncrypted);
    }
}
