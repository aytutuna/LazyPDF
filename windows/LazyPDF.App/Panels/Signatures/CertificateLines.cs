using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.App.Panels.Signatures;

// The facts of the certificate stored in the file, in plain words for the panel.
internal static class CertificateLines
{
    public static IReadOnlyList<string> Of(X509Certificate2 certificate)
    {
        return
        [
            Loc.T("Issued to: {0}", certificate.GetNameInfo(X509NameType.SimpleName, false) is { Length: > 0 } name ? name : certificate.Subject),
            Loc.T("Issued by: {0}", certificate.Issuer),
            Loc.T("Valid from {0} to {1}", certificate.NotBefore.ToString("d"), certificate.NotAfter.ToString("d")),
            Loc.T("Serial number: {0}", certificate.SerialNumber),
            Loc.T("Fingerprint (SHA-256): {0}", Fingerprint(certificate)),
            Loc.T("Key: {0}", Key(certificate)),
            Loc.T("Meant for: {0}", Purposes(certificate)),
            Loc.T("This is the certificate stored in the file. Whether it is trusted is shown above."),
        ];
    }

    public static string Fingerprint(X509Certificate2 certificate) => BitConverter.ToString(SHA256.HashData(certificate.RawData)).Replace('-', ' ');

    public static string Key(X509Certificate2 certificate)
    {
        string fallback = certificate.PublicKey.Oid.FriendlyName ?? "";
        try
        {
            using var rsa = certificate.GetRSAPublicKey();
            if (rsa is not null) return "RSA " + rsa.KeySize;
            using var ec = certificate.GetECDsaPublicKey();
            if (ec is not null) return ec.ExportParameters(false).Curve.Oid?.FriendlyName ?? fallback;
        }
        catch (CryptographicException)
        {
        }
        return fallback;
    }

    private static string Purposes(X509Certificate2 certificate)
    {
        try
        {
            var usages = certificate.Extensions.OfType<X509EnhancedKeyUsageExtension>().FirstOrDefault()?.EnhancedKeyUsages;
            if (usages is { Count: > 0 }) return string.Join(", ", usages.Cast<Oid>().Select(o => o.FriendlyName is { Length: > 0 } f ? f : o.Value));
        }
        catch (CryptographicException)
        {
        }
        return Loc.T("Not stated");
    }
}
