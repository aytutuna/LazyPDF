using Xunit;

namespace LazyPDF.Core.Tests;

public class PublicKeyProblemTests
{
    private static PdfReadProblem ProblemOf(Action open) => Assert.Throws<PdfReadException>(open).Problem;

    [Fact]
    public void NoCertificateNeedsOne()
    {
        var file = PublicKeyFiles.Seal(PublicKeyFiles.Alice);

        Assert.Equal(PdfReadProblem.CertificateRequired, ProblemOf(() => PdfDocument.Open(file)));
        Assert.Equal(PdfReadProblem.CertificateRequired, ProblemOf(() => PdfDocument.Open(file, "password")));
    }

    [Fact]
    public void CertificateOfSomeoneElseNeedsTheRightOne()
    {
        var file = PublicKeyFiles.Seal(PublicKeyFiles.Alice);

        Assert.Equal(PdfReadProblem.CertificateRequired, ProblemOf(() => PdfDocument.Open(file, PublicKeyFiles.Eve)));
    }

    [Fact]
    public void RightCertificateWithoutItsPrivateKeyIsNotEnough()
    {
        var file = PublicKeyFiles.Seal(PublicKeyFiles.Alice);

        Assert.Equal(PdfReadProblem.CertificateRequired, ProblemOf(() => PdfDocument.Open(file, PublicKeyFiles.PublicPart(PublicKeyFiles.Alice))));
    }

    [Fact]
    public void ProblemIsTheSameForBothStrengths()
    {
        var file = PublicKeyFiles.Seal(PublicKeyFiles.Alice, PdfCryptStrength.Aes128);

        Assert.Equal(PdfReadProblem.CertificateRequired, ProblemOf(() => PdfDocument.Open(file, PublicKeyFiles.Eve)));
    }

    [Fact]
    public void PasswordFileGivenACertificateStillWantsAPassword()
    {
        var file = PdfDocument.Open(PublicKeyFiles.Plain()).SaveRewrite(new PdfSaveOptions(
            Security: PdfSecurity.Create("user", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, new byte[16])));

        Assert.Equal(PdfReadProblem.PasswordRequired, ProblemOf(() => PdfDocument.Open(file, PublicKeyFiles.Alice)));
    }

    [Fact]
    public void PasswordFileWithAnEmptyUserPasswordOpensWithACertificate()
    {
        var file = PdfDocument.Open(PublicKeyFiles.Plain()).SaveRewrite(new PdfSaveOptions(
            Security: PdfSecurity.Create("", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, new byte[16])));

        using var document = PdfDocument.Open(file, PublicKeyFiles.Alice);

        Assert.False(document.Security!.IsPublicKey);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
    }

    [Fact]
    public void PlainFileIgnoresTheCertificate()
    {
        using var document = PdfDocument.Open(PublicKeyFiles.Plain(), PublicKeyFiles.Alice);

        Assert.False(document.IsEncrypted);
    }

    private static PdfDictionary Sealed(PdfCryptStrength strength = PdfCryptStrength.Aes256) =>
        PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], strength).Dictionary.Copy();

    private static PdfDictionary FilterOf(PdfDictionary dictionary) =>
        (PdfDictionary)((PdfDictionary)dictionary["CF"]!)["DefaultCryptFilter"]!;

    private static PdfReadProblem OpenProblem(PdfDictionary dictionary) =>
        ProblemOf(() => PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice));

    [Fact]
    public void UnknownSubFilterIsUnsupported()
    {
        var dictionary = Sealed();
        dictionary["SubFilter"] = new PdfName("adbe.pkcs7.s3");

        Assert.Equal(PdfReadProblem.Unsupported, OpenProblem(dictionary));
    }

    [Fact]
    public void VersionThatDoesNotFitTheSubFilterIsUnsupported()
    {
        var dictionary = Sealed();
        dictionary["V"] = new PdfNumber(4);

        Assert.Equal(PdfReadProblem.Unsupported, OpenProblem(dictionary));
    }

    [Fact]
    public void CipherThatDoesNotFitTheVersionIsUnsupported()
    {
        var dictionary = Sealed();
        FilterOf(dictionary)["CFM"] = new PdfName("AESV2");

        Assert.Equal(PdfReadProblem.Unsupported, OpenProblem(dictionary));
    }

    [Fact]
    public void MissingRecipientsIsDamaged()
    {
        var dictionary = Sealed();
        FilterOf(dictionary).Remove("Recipients");

        Assert.Equal(PdfReadProblem.Damaged, OpenProblem(dictionary));
    }

    [Fact]
    public void MissingCryptFilterIsDamaged()
    {
        var dictionary = Sealed();
        dictionary.Remove("CF");

        Assert.Equal(PdfReadProblem.Damaged, OpenProblem(dictionary));
    }

    [Fact]
    public void GarbageRecipientsAreNotACrash()
    {
        var dictionary = Sealed();
        var list = (PdfArray)FilterOf(dictionary)["Recipients"]!;
        list.Items.Insert(0, new PdfString([1, 2, 3], true));
        list.Items.Insert(1, new PdfString([], true));
        list.Items.Insert(2, new PdfNumber(7));

        Assert.NotNull(PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice));
    }

    [Fact]
    public void OnlyGarbageRecipientsIsAWrongCertificate()
    {
        var dictionary = Sealed();
        FilterOf(dictionary)["Recipients"] = new PdfArray([new PdfString([0x30, 0x03, 0x02, 0x01, 0x00], true)]);

        Assert.Null(PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice));
    }

    [Fact]
    public void AlteredRecipientListGivesNoKeyForTheFileToBeRead()
    {
        // The file key is a digest over every recipient entry, so one added entry changes what the stream data decrypts to.
        var created = PdfSecurity.CreatePublicKey([new PdfRecipient(PublicKeyFiles.Alice)], PdfCryptStrength.Aes256);
        byte[] cipher = created.EncryptString(3, 0, "secret"u8.ToArray());
        var dictionary = created.Dictionary.Copy();
        ((PdfArray)FilterOf(dictionary)["Recipients"]!).Items.Add(new PdfString([9], true));

        var reader = PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice)!;

        Assert.NotEqual("secret"u8.ToArray(), reader.DecryptString(3, 0, cipher));
    }

    [Fact]
    public void ManyRecipientsAreReadOnlyToALimit()
    {
        var dictionary = Sealed();
        var list = (PdfArray)FilterOf(dictionary)["Recipients"]!;
        var real = list.Items[0];
        list.Items.Clear();
        for (int i = 0; i < 1500; i++) list.Items.Add(new PdfString([0x30, 0x00], true));
        list.Items.Add(real);

        Assert.Null(PdfSecurity.OpenPublicKey(dictionary, PublicKeyFiles.Alice));
    }
}
