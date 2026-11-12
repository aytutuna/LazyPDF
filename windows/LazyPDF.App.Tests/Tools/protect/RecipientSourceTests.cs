using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Tools.Protect;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Protect;

public sealed class RecipientSourceTests
{
    private static byte[] RsaCertificate()
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=Ada Lovelace", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1)).RawData;
    }

    [Fact]
    public void ACertificateFileInEitherFormIsRead()
    {
        using var dir = new TempDir();
        byte[] der = RsaCertificate();
        string cer = dir.File("ada.cer", der);
        string pem = dir.File("ada.pem", System.Text.Encoding.ASCII.GetBytes(PemEncoding.WriteString("CERTIFICATE", der)));

        var fromDer = RecipientSource.FromFile(cer);
        var fromPem = RecipientSource.FromFile(pem);

        Assert.Equal("Ada Lovelace", fromDer!.Name);
        Assert.Equal(fromDer.Certificate.Thumbprint, fromPem!.Certificate.Thumbprint);
        Assert.False(fromDer.HasPrivateKey);
    }

    [Fact]
    public void AStoreThatDoesNotExistIsSkipped() =>
        Assert.NotNull(RecipientSource.FromStore());

    [Fact]
    public void AFileThatIsNotACertificateIsRefused()
    {
        using var dir = new TempDir();

        Assert.Null(RecipientSource.FromFile(dir.File("notes.cer", "not a certificate"u8.ToArray())));
    }

    [Fact]
    public void ACertificateWithAnUnsupportedCurveIsRefused()
    {
        using var dir = new TempDir();
        using var ec = ECDsa.Create(ECCurve.NamedCurves.nistP521);
        var request = new CertificateRequest("CN=Curve", ec, HashAlgorithmName.SHA256);
        string file = dir.File("ec.cer", request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1)).RawData);

        Assert.Null(RecipientSource.FromFile(file));
    }

    [Fact]
    public void ASigningOnlyCertificateIsRefused()
    {
        using var dir = new TempDir();
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=Signer", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation, true));
        string file = dir.File("sign.cer", request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1)).RawData);

        Assert.Null(RecipientSource.FromFile(file));
    }

    [Fact]
    public void ADetailLineSaysWhoIssuedItAndUntilWhen()
    {
        using var dir = new TempDir();
        var recipient = RecipientSource.FromFile(dir.File("ada.cer", RsaCertificate()))!;

        Assert.False(recipient.Expired);
        Assert.Contains("Ada Lovelace", recipient.Details);
        Assert.Contains(recipient.Certificate.NotAfter.ToString("d"), recipient.Details);
    }
}
