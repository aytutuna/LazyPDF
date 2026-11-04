using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace LazyPDF.Core.Tests;

internal static class PublicKeyFiles
{
    public const string PageText = "(Sealed for recipients) Tj";

    // Key generation is slow, so the certificates are made once per run.
    private static readonly Lazy<X509Certificate2> First = new(() => Certificate("First"));
    private static readonly Lazy<X509Certificate2> Second = new(() => Certificate("Second"));
    private static readonly Lazy<X509Certificate2> Stranger = new(() => Certificate("Stranger"));

    public static X509Certificate2 Alice => First.Value;
    public static X509Certificate2 Bob => Second.Value;
    public static X509Certificate2 Eve => Stranger.Value;

    /// <summary>A self-signed RSA certificate with its private key, loaded the way a key from a PFX file is.</summary>
    public static X509Certificate2 Certificate(string name)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest($"CN={name}", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyEncipherment | X509KeyUsageFlags.DataEncipherment, true));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        using var made = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(1));
        return X509CertificateLoader.LoadPkcs12(made.Export(X509ContentType.Pfx, "pw"), "pw");
    }

    /// <summary>The certificate alone, as a recipient list or an address book has it.</summary>
    public static X509Certificate2 PublicPart(X509Certificate2 certificate) => X509CertificateLoader.LoadCertificate(certificate.RawData);

    /// <summary>A one-page file with <see cref="PageText"/> in its content stream.</summary>
    public static byte[] Plain() => new TestPdf()
        .Obj(1, "<</Type/Catalog/Pages 2 0 R>>")
        .Obj(2, "<</Type/Pages/Kids[3 0 R]/Count 1>>")
        .Obj(3, "<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>")
        .Stream(4, "", "BT /F1 12 Tf 20 100 Td " + PageText + " ET")
        .Obj(5, "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>")
        .Obj(6, "<</Title(Sealed title)>>")
        .Finish("/Root 1 0 R /Info 6 0 R");

    public static byte[] Seal(IReadOnlyList<PdfRecipient> recipients, PdfCryptStrength strength = PdfCryptStrength.Aes256, bool objectStreams = false) =>
        PdfDocument.Open(Plain()).SaveRewrite(new PdfSaveOptions(objectStreams, PdfSecurity.CreatePublicKey(recipients, strength)));

    public static byte[] Seal(X509Certificate2 certificate, PdfCryptStrength strength = PdfCryptStrength.Aes256) =>
        Seal([new PdfRecipient(certificate)], strength);

    public static string Content(PdfDocument document) => Encoding.Latin1.GetString(document.Pages[0].Contents());
}
