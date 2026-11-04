using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>
/// A person a public-key file is encrypted for. <paramref name="CanChangeEncryption"/> is bit 2 of
/// the recipient's permissions (ISO 32000-1 7.6.4.3, table 24): this recipient may change or remove
/// the encryption, the counterpart of the owner password.
/// </summary>
public sealed record PdfRecipient(X509Certificate2 Certificate, PdfPermissions Permissions = PdfPermissions.All,
                                  bool CanChangeEncryption = false);
