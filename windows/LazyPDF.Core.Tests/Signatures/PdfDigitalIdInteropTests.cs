using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>
/// The PFX file the Swift engine writes (Tests/Fixtures/golden/signatures/swift-export.pfx) opens here, and the
/// certificate and key it was made from are written from here (LAZYPDF_WRITE_GOLDEN=1), so that both sides are
/// checked against the same bytes.
/// </summary>
public class PdfDigitalIdInteropTests
{
    private const string Password = "pass word";
    private static readonly DateTimeOffset Start = new(2026, 3, 1, 0, 0, 0, TimeSpan.Zero);

    private static string SourceFolder([CallerFilePath] string path = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, "..", "..", "..", "Tests", "Fixtures", "golden", "signatures"));

    private static byte[] Fixture(string name) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "signatures", name));

    [Fact]
    public void The_certificate_and_key_the_Swift_writer_starts_from_are_written_here()
    {
        if (Environment.GetEnvironmentVariable("LAZYPDF_WRITE_GOLDEN") != "1") return;
        using var id = PdfDigitalId.Create("Ada Lovelace", null, Start, keyBits: 2048);
        using var key = id.GetRSAPrivateKey()!;
        Directory.CreateDirectory(SourceFolder());
        File.WriteAllBytes(Path.Combine(SourceFolder(), "id-cert.der"), id.RawData);
        File.WriteAllBytes(Path.Combine(SourceFolder(), "id-key.pkcs1"), key.ExportRSAPrivateKey());
    }

    [Fact]
    public void A_pfx_the_Swift_engine_wrote_opens_and_signs()
    {
        using var certificate = X509CertificateLoader.LoadCertificate(Fixture("id-cert.der"));

        using var loaded = PdfDigitalId.ImportPfx(Fixture("swift-export.pfx"), Password);

        Assert.Equal(certificate.Thumbprint, loaded.Thumbprint);
        Assert.True(loaded.HasPrivateKey);
        using var key = loaded.GetRSAPrivateKey()!;
        using var expected = RSA.Create();
        expected.ImportRSAPrivateKey(Fixture("id-key.pkcs1"), out _);
        Assert.Equal(expected.ExportRSAPublicKey(), key.ExportRSAPublicKey());
        Assert.Equal(SignatureVerdict.ValidButUntrusted,
            Assert.Single(PdfSignatureVerifier.Verify(PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(loaded, Pki.Signing)))).Verdict);
        Assert.ThrowsAny<CryptographicException>(() => PdfDigitalId.ImportPfx(Fixture("swift-export.pfx"), "wrong"));
    }
}
