using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A file opened with a certificate is read again, for text, for a display copy and for its signatures, with that same certificate.
public sealed class CertificateReadersTests
{
    private static X509Certificate2 NewCertificate()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Alice", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyEncipherment | X509KeyUsageFlags.DataEncipherment, critical: false));
        using var made = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        return X509CertificateLoader.LoadPkcs12(made.Export(X509ContentType.Pfx), null);
    }

    private static byte[] EncryptedFor(X509Certificate2 certificate) =>
        PdfDocument.Open(Pdfs.Text()).SaveRewrite(new PdfSaveOptions(false, PdfSecurity.CreatePublicKey([new PdfRecipient(certificate)], PdfCryptStrength.Aes256)));

    [Fact]
    public async Task TheTabKeepsTheCertificateItWasOpenedWith()
    {
        using var f = new ViewModelFixture();
        var alice = NewCertificate();
        await f.Vm.OpenAsync(f.Dir.File("secret.pdf", EncryptedFor(alice)));

        await f.Vm.SubmitCertificateAsync(new CertificateChoice(alice, "Alice", "Alice", alice.NotAfter, true));

        Assert.Same(alice, f.Vm.ActiveDocument!.Certificate);
    }

    [Fact]
    public async Task TextIsReadFromAFileForRecipients()
    {
        var alice = NewCertificate();
        byte[] bytes = EncryptedFor(alice);

        Assert.Null(await TextSource.OpenAsync(bytes, null));
        var source = await TextSource.OpenAsync(bytes, null, alice);

        Assert.NotNull(source);
        Assert.Contains("Hello", (await source!.GetAsync(0))!.Text);
    }

    [Fact]
    public void ADisplayCopyIsMadeFromAFileForRecipients()
    {
        var alice = NewCertificate();
        byte[] bytes = EncryptedFor(alice);

        Assert.Null(DisplayCopy.Create(bytes, null, []));
        using var copy = DisplayCopy.Create(bytes, null, [], alice)!.Renderer;

        Assert.NotNull(copy.Render(0, 72));
    }

    [Fact]
    public void SignaturesAreCheckedInAFileForRecipients()
    {
        var alice = NewCertificate();
        byte[] bytes = EncryptedFor(alice);

        Assert.Throws<PdfReadException>(() => PdfSignatureVerifier.Verify(bytes));
        Assert.Empty(PdfSignatureVerifier.Verify(bytes, new VerifyOptions { Certificate = alice }));
    }
}
