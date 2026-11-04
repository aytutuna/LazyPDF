using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RedactEncryptedTests
{
    private static readonly byte[] Id = [.. Enumerable.Range(1, 16).Select(i => (byte)i)];

    private static byte[] Locked(PdfCryptStrength strength)
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (public ZQXMARKER public) Tj ET");
        return document.SaveRewrite(new PdfSaveOptions(Security: PdfSecurity.Create("user", "owner", PdfPermissions.All, strength, Id), DocumentId: Id));
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void EncryptedInputComesOutEncryptedWithTheSamePassword(PdfCryptStrength strength)
    {
        var bytes = Locked(strength);
        Assert.Throws<PdfReadException>(() => PdfDocument.Open(bytes, "wrong"));
        using var document = PdfDocument.Open(bytes, "user");
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"));
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.Throws<PdfReadException>(() => PdfDocument.Open(result.Bytes, "wrong"));
        using var output = RedactionKit.Reopen(result.Bytes, "user");
        Assert.True(output.IsEncrypted);
        Assert.Equal("public  public", RedactionKit.Text(output));
        Assert.False(RedactionKit.Holds(result.Bytes, RedactionKit.Marker, "user"));
    }

    [Fact]
    public void EncryptionCanBeLeftOff()
    {
        using var document = PdfDocument.Open(Locked(PdfCryptStrength.Aes256), "owner");
        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"), new RedactionOptions { KeepEncryption = false });
        using var output = RedactionKit.Reopen(result.Bytes);
        Assert.False(output.IsEncrypted);
        Assert.False(RedactionKit.Holds(result.Bytes, RedactionKit.Marker));
    }

    [Fact]
    public void SignedFileIsRedactedAndSaysItsSignaturesAreGone()
    {
        using var document = RedactionKit.Page("BT /F1 12 Tf 100 700 Td (ZQXMARKER) Tj ET");
        var signature = document.Add(new PdfDictionary
        {
            ["Type"] = new PdfName("Sig"), ["Filter"] = new PdfName("Adobe.PPKLite"), ["SubFilter"] = new PdfName("adbe.pkcs7.detached"),
            ["ByteRange"] = new PdfArray([new PdfNumber(0), new PdfNumber(10), new PdfNumber(20), new PdfNumber(30)]),
            ["Contents"] = new PdfString(new byte[64], isHex: true),
        });
        var field = document.Add(new PdfDictionary
        {
            ["Type"] = new PdfName("Annot"), ["Subtype"] = new PdfName("Widget"), ["FT"] = new PdfName("Sig"), ["T"] = PdfText.ToObject("Signature1"),
            ["V"] = signature, ["Rect"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(0), new PdfNumber(0)]), ["P"] = document.Pages[0].Reference,
        });
        document.Pages[0].Dictionary["Annots"] = new PdfArray([field]);
        document.Catalog["AcroForm"] = new PdfDictionary { ["Fields"] = new PdfArray([field]), ["SigFlags"] = new PdfNumber(3) };
        Assert.True(document.IsSigned);

        var result = new PdfRedactor(document).Apply(RedactionKit.MarksOf(document, 0, "ZQXMARKER"));
        using var output = RedactionKit.Open(result);
        Assert.Equal(1, result.Report.SignaturesRemoved);
        Assert.Contains("signature is gone", result.Report.ToString());
        Assert.False(output.IsSigned);
        Assert.DoesNotContain("ByteRange", System.Text.Encoding.Latin1.GetString(result.Bytes));
        Assert.Equal("Signature1", Assert.Single(PdfForm.Read(output).Fields).Name);
    }
}
