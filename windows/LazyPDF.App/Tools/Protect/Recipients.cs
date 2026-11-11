using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Protect;

/// <summary>A certificate the file is locked for. Whoever holds its private key here may also change the protection later.</summary>
public sealed record Recipient(X509Certificate2 Certificate)
{
    public string Name => Certificate.GetNameInfo(X509NameType.SimpleName, false);

    public string Issuer => Certificate.GetNameInfo(X509NameType.SimpleName, true);

    public bool HasPrivateKey => Certificate.HasPrivateKey;

    public bool Expired => Certificate.NotAfter < DateTime.Now;

    public string Details => Expired ? Loc.T("{0}, expired {1}", Issuer, Certificate.NotAfter.ToString("d")) : Loc.T("{0}, valid until {1}", Issuer, Certificate.NotAfter.ToString("d"));

    public PdfRecipient ToPdfRecipient(PdfPermissions allowed) => new(Certificate, allowed, CanChangeEncryption: HasPrivateKey);
}

public static class RecipientSource
{
    /// <summary>Reads a certificate file (DER or PEM). Null when it is not one, or its key cannot lock a PDF.</summary>
    public static Recipient? FromFile(string path)
    {
        try
        {
            var certificate = X509CertificateLoader.LoadCertificateFromFile(path);
            return !PdfRecipient.CanProtect(certificate) ? null : new Recipient(WithStoredKey(certificate));
        }
        catch (System.Security.Cryptography.CryptographicException)
        {
            return null;
        }
    }

    // A certificate file carries no key; when the same certificate is in the user's own store the key is there.
    private static X509Certificate2 WithStoredKey(X509Certificate2 certificate)
    {
        try
        {
            using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
            return store.Certificates.Find(X509FindType.FindByThumbprint, certificate.Thumbprint, false)
                .FirstOrDefault(c => c.HasPrivateKey) ?? certificate;
        }
        catch (System.Security.Cryptography.CryptographicException)
        {
            return certificate;
        }
    }

    /// <summary>Your own certificates and the ones kept for other people, RSA keys that can encrypt only, valid ones first.</summary>
    public static IReadOnlyList<Recipient> FromStore()
    {
        var found = new Dictionary<string, Recipient>();
        foreach (var name in new[] { StoreName.My, StoreName.AddressBook, StoreName.TrustedPeople })
        {
            using var store = new X509Store(name, StoreLocation.CurrentUser);
            try
            {
                store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly);
            }
            catch (System.Security.Cryptography.CryptographicException)
            {
                continue;
            }
            foreach (var certificate in store.Certificates)
            {
                if (PdfRecipient.CanProtect(certificate)) found.TryAdd(certificate.Thumbprint, new Recipient(certificate));
            }
        }
        return [.. found.Values.OrderBy(r => r.Expired).ThenBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase)];
    }
}
