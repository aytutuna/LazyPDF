using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What the user decided about trust and time stamp servers, kept in signing.json.
public sealed class SigningSettingsTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 10, 9, 0, 0, TimeSpan.Zero);

    [Fact]
    public void WindowsRootsAreTrustedUntilTheUserSaysOtherwise()
    {
        using var dir = new TempDir();

        var loaded = SigningSettingsStore.Load(dir.Path);

        Assert.True(loaded.TrustWindowsStore);
        Assert.Empty(loaded.TrustedCertificates);
        Assert.Equal("http://timestamp.digicert.com", loaded.TimestampUrl);
    }

    [Fact]
    public void An_emptied_time_stamp_address_stays_empty()
    {
        using var dir = new TempDir();
        SigningSettingsStore.Update(s => s.TimestampUrl = "", dir.Path);

        Assert.Equal("", SigningSettingsStore.Load(dir.Path).TimestampUrl);
    }

    [Fact]
    public void ChangesAreReadBackAndEachPartKeepsTheOthers()
    {
        using var dir = new TempDir();
        SigningSettingsStore.Update(s => s.TimestampUrl = "http://tsa.example/stamp", dir.Path);
        SigningSettingsStore.Update(s => s.TrustWindowsStore = false, dir.Path);
        SigningSettingsStore.Update(s => s.TrustedCertificates.Add("AAAA"), dir.Path);

        var loaded = SigningSettingsStore.Load(dir.Path);

        Assert.Equal("http://tsa.example/stamp", loaded.TimestampUrl);
        Assert.False(loaded.TrustWindowsStore);
        Assert.Equal(["AAAA"], loaded.TrustedCertificates);
    }

    [Fact]
    public void TheVerifierGetsTheAnchorsAndSkipsWhatDoesNotParse()
    {
        using var certificate = PdfDigitalId.Create("Ada", null, Now.AddDays(-1), years: 1, keyBits: 2048);
        var settings = new SigningSettings
        {
            TrustWindowsStore = false,
            TrustedCertificates = [Convert.ToBase64String(certificate.RawData), "not base64!", Convert.ToBase64String([1, 2, 3])],
        };

        var options = settings.Verify("secret", null, Now);

        Assert.False(options.UseSystemStore);
        Assert.Equal(certificate.Thumbprint, Assert.Single(options.TrustAnchors).Thumbprint);
        Assert.Equal("secret", options.Password);
        Assert.Equal(Now, options.Now);
    }

    [Fact]
    public void ACertificateAsPemIsReadByTheLoader()
    {
        using var certificate = PdfDigitalId.Create("Ada", null, Now.AddDays(-1), years: 1, keyBits: 2048);
        byte[] pem = System.Text.Encoding.ASCII.GetBytes(certificate.ExportCertificatePem());

        using var loaded = X509CertificateLoader.LoadCertificate(pem);

        Assert.Equal(certificate.Thumbprint, loaded.Thumbprint);
    }
}
