using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A file encrypted for recipients asks for a certificate, not a password, and is drawn once it is open.
public sealed class CertificateFlowTests
{
    private static X509Certificate2 NewCertificate(string name)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=" + name, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyEncipherment | X509KeyUsageFlags.DataEncipherment, critical: false));
        using var made = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        return X509CertificateLoader.LoadPkcs12(made.Export(X509ContentType.Pfx), null);
    }

    private static byte[] EncryptedFor(X509Certificate2 certificate) =>
        PdfDocument.Open(Pdfs.Text()).SaveRewrite(new PdfSaveOptions(false, PdfSecurity.CreatePublicKey([new PdfRecipient(certificate)], PdfCryptStrength.Aes256)));

    private static CertificateChoice Choice(X509Certificate2 certificate) =>
        new(certificate, "Test", "Test", certificate.NotAfter, IsValidNow: true);

    [Fact]
    public async Task AFileForRecipientsAsksForACertificate()
    {
        using var f = new ViewModelFixture();
        var alice = NewCertificate("Alice");

        await f.Vm.OpenAsync(f.Dir.File("secret.pdf", EncryptedFor(alice)));

        var request = f.Vm.PasswordRequest!;
        Assert.True(request.NeedsCertificate);
        Assert.Empty(f.Vm.Documents);
    }

    [Fact]
    public async Task TheRightCertificateOpensItAndItIsDrawn()
    {
        using var f = new ViewModelFixture();
        var alice = NewCertificate("Alice");
        await f.Vm.OpenAsync(f.Dir.File("secret.pdf", EncryptedFor(alice)));

        await f.Vm.SubmitCertificateAsync(Choice(alice));

        Assert.Null(f.Vm.PasswordRequest);
        Assert.Equal("secret.pdf", f.Vm.ActiveDocument?.Title);
    }

    [Fact]
    public async Task AnotherCertificateIsSaidToBeWrongAndAsksAgain()
    {
        using var f = new ViewModelFixture();
        var alice = NewCertificate("Alice");
        var mallory = NewCertificate("Mallory");
        await f.Vm.OpenAsync(f.Dir.File("secret.pdf", EncryptedFor(alice)));

        await f.Vm.SubmitCertificateAsync(Choice(mallory));

        var request = f.Vm.PasswordRequest!;
        Assert.True(request.NeedsCertificate);
        Assert.Equal("That certificate does not open this file.", request.Problem);
        Assert.Equal(1, request.Attempts);
    }

    [Fact]
    public void TheEngineDecryptsAPublicKeyFileForTheSystemToDraw()
    {
        var alice = NewCertificate("Alice");
        var session = PdfEditSession.Open(EncryptedFor(alice), alice);
        using var renderer = new WindowsPageRenderer();

        Assert.True(renderer.Load(session, null));

        Assert.NotNull(renderer.Render(0, 72));
    }
}
