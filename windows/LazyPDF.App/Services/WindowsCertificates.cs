using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.App.Services;

/// <summary>A certificate the user can sign or open a file with.</summary>
public sealed record CertificateChoice(X509Certificate2 Certificate, string Name, string Issuer, DateTime Expires, bool IsValidNow)
{
    public string Thumbprint => Certificate.Thumbprint;
}

/// <summary>The personal certificates in the Windows store (Current User, My).</summary>
public static class WindowsCertificates
{
    /// <summary>Those with a private key that can sign, valid ones first, then by name.</summary>
    public static IReadOnlyList<CertificateChoice> WithPrivateKey()
    {
        using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
        store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
        return Choices(store.Certificates);
    }

    internal static IReadOnlyList<CertificateChoice> Choices(IEnumerable<X509Certificate2> certificates, DateTime? now = null)
    {
        var at = now ?? DateTime.Now;
        return
        [
            .. certificates.Where(c => c.HasPrivateKey && CanSign(c))
                .Select(c => new CertificateChoice(c, c.GetNameInfo(X509NameType.SimpleName, false), c.GetNameInfo(X509NameType.SimpleName, true), c.NotAfter, c.NotBefore <= at && at <= c.NotAfter))
                .OrderByDescending(c => c.IsValidNow)
                .ThenBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase),
        ];
    }

    private static bool CanSign(X509Certificate2 c) =>
        c.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault() is not { } usage
        || (usage.KeyUsages & (X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation)) != 0;
}
