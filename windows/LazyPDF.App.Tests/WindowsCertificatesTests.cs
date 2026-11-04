using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class WindowsCertificatesTests
{
    private static X509Certificate2 Make(string name, DateTimeOffset from, DateTimeOffset to, bool withKey)
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=" + name, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var made = request.CreateSelfSigned(from, to);
        return withKey
            ? X509CertificateLoader.LoadPkcs12(made.Export(X509ContentType.Pfx), null)
            : X509CertificateLoader.LoadCertificate(made.Export(X509ContentType.Cert));
    }

    [Fact]
    public void OnlyCertificatesWithAPrivateKeyAreOffered()
    {
        var now = DateTimeOffset.Now;
        var certificates = new[]
        {
            Make("With key", now.AddDays(-1), now.AddYears(1), withKey: true),
            Make("Without key", now.AddDays(-1), now.AddYears(1), withKey: false),
        };

        var choices = WindowsCertificates.Choices(certificates);

        Assert.Equal(["With key"], choices.Select(c => c.Name));
    }

    [Fact]
    public void ValidOnesComeFirstThenByName()
    {
        var now = DateTimeOffset.Now;
        var certificates = new[]
        {
            Make("Zeta", now.AddDays(-1), now.AddYears(1), withKey: true),
            Make("Expired", now.AddYears(-3), now.AddYears(-1), withKey: true),
            Make("Alpha", now.AddDays(-1), now.AddYears(1), withKey: true),
        };

        var choices = WindowsCertificates.Choices(certificates);

        Assert.Equal(["Alpha", "Zeta", "Expired"], choices.Select(c => c.Name));
        Assert.Equal([true, true, false], choices.Select(c => c.IsValidNow));
    }

    [Fact]
    public void AChoiceCarriesItsThumbprintAndIssuer()
    {
        var now = DateTimeOffset.Now;
        var certificate = Make("Carol", now.AddDays(-1), now.AddYears(1), withKey: true);

        var choice = Assert.Single(WindowsCertificates.Choices([certificate]));

        Assert.Equal(certificate.Thumbprint, choice.Thumbprint);
        Assert.Equal("Carol", choice.Issuer);
    }

    [Fact]
    public void TheWindowsStoreCanBeListed()
    {
        var choices = WindowsCertificates.WithPrivateKey();

        Assert.All(choices, c => Assert.True(c.Certificate.HasPrivateKey));
    }
}
