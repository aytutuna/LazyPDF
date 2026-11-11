using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Panels.Signatures;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The certificate facts the Signatures panel shows instead of the Windows viewer.
public sealed class CertificateLinesTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 10, 9, 0, 0, TimeSpan.Zero);

    [Fact]
    public void EachFactHasItsOwnLine()
    {
        using var ada = PdfDigitalId.Create("Ada Lovelace", null, Now, years: 1, keyBits: 2048);

        var lines = CertificateLines.Of(ada);

        Assert.Equal(8, lines.Count);
        Assert.Equal("Issued to: Ada Lovelace", lines[0]);
        Assert.Equal("Issued by: CN=Ada Lovelace", lines[1]);
        Assert.Equal($"Valid from {ada.NotBefore:d} to {ada.NotAfter:d}", lines[2]);
        Assert.Equal("Serial number: " + ada.SerialNumber, lines[3]);
        Assert.Equal("Key: RSA 2048", lines[5]);
        Assert.StartsWith("Meant for: ", lines[6]);
        Assert.Contains(", ", lines[6]);
        Assert.Equal("This is the certificate stored in the file. Whether it is trusted is shown above.", lines[7]);
    }

    [Fact]
    public void TheFingerprintIsSha256InGroupsOfTwo()
    {
        using var ada = PdfDigitalId.Create("Ada Lovelace", null, Now, years: 1, keyBits: 2048);

        string line = CertificateLines.Of(ada)[4];

        string expected = string.Join(' ', SHA256.HashData(ada.RawData).Select(b => b.ToString("X2")));
        Assert.Equal("Fingerprint (SHA-256): " + expected, line);
        Assert.Equal(32, expected.Split(' ').Length);
        Assert.Equal(expected, CertificateLines.Fingerprint(ada));
    }

    [Fact]
    public void ACertificateWithoutPurposesSaysNotStated()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Plain", key, HashAlgorithmName.SHA256);
        using var plain = request.CreateSelfSigned(Now, Now.AddYears(1));

        var lines = CertificateLines.Of(plain);

        Assert.Equal("Meant for: Not stated", lines[6]);
        Assert.StartsWith("Key: ", lines[5]);
        Assert.Contains("256", lines[5]);
    }

    [Fact]
    public void AMalformedPurposesExtensionSaysNotStated()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Odd", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509Extension("2.5.29.37", [0x01, 0x02, 0x03], false));
        using var odd = request.CreateSelfSigned(Now, Now.AddYears(1));

        var lines = CertificateLines.Of(odd);

        Assert.Equal("Meant for: Not stated", lines[6]);
    }
}
