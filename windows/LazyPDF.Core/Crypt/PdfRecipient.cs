using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>
/// A person a public-key file is encrypted for. <paramref name="CanChangeEncryption"/> is bit 2 of
/// the recipient's permissions (ISO 32000-1 7.6.4.3, table 24): this recipient may change or remove
/// the encryption, the counterpart of the owner password.
/// </summary>
public sealed record PdfRecipient(X509Certificate2 Certificate, PdfPermissions Permissions = PdfPermissions.All,
                                  bool CanChangeEncryption = false)
{
    /// <summary>
    /// Whether a file can be encrypted for <paramref name="certificate"/>: it has an RSA key, and its key usage,
    /// if it states one, allows enciphering. Key agreement (EC) certificates are not supported.
    /// </summary>
    public static bool CanProtect(X509Certificate2 certificate)
    {
        using var key = certificate.GetRSAPublicKey();
        if (key is null) return false;
        var usage = certificate.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault();
        return usage is null || (usage.KeyUsages & (X509KeyUsageFlags.KeyEncipherment | X509KeyUsageFlags.DataEncipherment)) != 0;
    }
}
