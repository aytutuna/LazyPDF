using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>A self-signed certificate for people who have none. Signatures made with it show as "not trusted" everywhere but where it is added as trusted by hand.</summary>
public static class PdfDigitalId
{
    private const string EmailProtection = "1.3.6.1.5.5.7.3.4";
    private const string PdfSigning = "1.2.840.113583.1.1.5";

    /// <summary>
    /// A certificate for <paramref name="name"/> (and <paramref name="email"/> when given) valid for <paramref name="years"/>
    /// from <paramref name="notBefore"/>, which is the caller's clock. The key is an exportable RSA key of <paramref name="keyBits"/>.
    /// </summary>
    public static X509Certificate2 Create(string name, string? email, DateTimeOffset notBefore, int years = 10, int keyBits = 3072)
    {
        var subject = new X500DistinguishedName(email is { Length: > 0 } ? $"CN={Escape(name)}, E={Escape(email)}" : $"CN={Escape(name)}");
        using var key = RSA.Create(keyBits);
        var request = new CertificateRequest(subject, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid(EmailProtection), new Oid(PdfSigning)], false));
        request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        if (email is { Length: > 0 })
        {
            var names = new SubjectAlternativeNameBuilder();
            names.AddEmailAddress(email);
            request.CertificateExtensions.Add(names.Build());
        }
        return request.CreateSelfSigned(notBefore, notBefore.AddYears(years));
    }

    /// <summary>The certificate and its private key as a PFX file protected by <paramref name="password"/>.</summary>
    public static byte[] ExportPfx(X509Certificate2 certificate, string password) => certificate.Export(X509ContentType.Pfx, password);

    public static X509Certificate2 ImportPfx(byte[] pfx, string password) =>
        X509CertificateLoader.LoadPkcs12(pfx, password, X509KeyStorageFlags.Exportable);

    // A comma or a quote in a name would end its attribute early.
    private static string Escape(string value) =>
        "\"" + value.Replace("\"", "\"\"") + "\"";
}
