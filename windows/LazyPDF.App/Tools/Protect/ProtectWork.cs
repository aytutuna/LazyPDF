using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Protect;

/// <summary>
/// What the person allows once the file is open. Print in high quality only counts while printing is allowed, and
/// adding comments always allows filling in forms. Reading aloud stays allowed: readers ignore that bit in the current standard.
/// </summary>
public sealed record PermissionChoices(bool Print, bool PrintHighQuality, bool Copy, bool Edit, bool Comment, bool FillForms, bool Assemble)
{
    public static PermissionChoices Everything { get; } = new(true, true, true, true, true, true, true);

    public PdfPermissions ToPermissions()
    {
        var allowed = PdfPermissions.None;
        if (Print) allowed |= PdfPermissions.Print;
        if (Print && PrintHighQuality) allowed |= PdfPermissions.PrintHighQuality;
        if (Copy) allowed |= PdfPermissions.Copy;
        if (Edit) allowed |= PdfPermissions.Modify;
        if (Comment) allowed |= PdfPermissions.Annotate;
        if (FillForms || Comment) allowed |= PdfPermissions.FillForms;
        if (Assemble) allowed |= PdfPermissions.Assemble;
        return allowed | PdfPermissions.ExtractForAccessibility;
    }
}

/// <summary>Writes a protected or an open copy of a document. Encryption is made by a rewrite, which an update on top of the file cannot do.</summary>
public static class ProtectWork
{
    public static byte[] WithPassword(PdfDocument document, string openPassword, string ownerPassword, PdfPermissions allowed, PdfCryptStrength strength)
    {
        byte[] id = RandomNumberGenerator.GetBytes(16);
        var security = PdfSecurity.Create(openPassword, ownerPassword, allowed, strength, id);
        byte[] bytes = document.SaveRewrite(new PdfSaveOptions(document.PdfAPart != 1, security, id));
        using (var back = PdfDocument.Open(bytes, openPassword)) CheckPages(back, document);
        return bytes;
    }

    /// <summary>The copy for the recipients, and the certificate of one of them that opens it here; null when none does.</summary>
    public static (byte[] Bytes, X509Certificate2? Opener) ForRecipients(PdfDocument document, IReadOnlyList<PdfRecipient> recipients, PdfCryptStrength strength)
    {
        var security = PdfSecurity.CreatePublicKey(recipients, strength);
        byte[] bytes = document.SaveRewrite(new PdfSaveOptions(document.PdfAPart != 1, security));
        // HasPrivateKey does not mean the key can decrypt: a card may be out, or the key may be for signing only.
        foreach (var recipient in recipients.Where(r => r.Certificate.HasPrivateKey))
        {
            PdfDocument back;
            try
            {
                back = PdfDocument.Open(bytes, recipient.Certificate);
            }
            catch (Exception e) when (e is PdfReadException { Problem: PdfReadProblem.CertificateRequired } or CryptographicException)
            {
                continue;
            }
            using (back) CheckPages(back, document);
            return (bytes, recipient.Certificate);
        }
        return (bytes, null);
    }

    public static byte[] Remove(PdfDocument document)
    {
        byte[] bytes = document.SaveRewrite(new PdfSaveOptions(document.PdfAPart != 1));
        using var back = PdfDocument.Open(bytes);
        CheckPages(back, document);
        return bytes;
    }

    private static void CheckPages(PdfDocument written, PdfDocument source)
    {
        if (written.Pages.Count != source.Pages.Count) throw PdfReadException.Damaged("The copy has another number of pages.");
    }

    /// <summary>
    /// Whether the boxes describe a protection that can be made: the two passwords agree, and the permissions password,
    /// when limits are set, is another word than the one to open. An empty password to open is fine when the limits are what the file is for.
    /// </summary>
    public static bool PasswordsAgree(string open, string repeat, bool limited, string owner) =>
        (open.Length > 0 || limited) && open == repeat && (!limited || owner.Length > 0 && owner != open);

    /// <summary>True when the file restricts what its reader may do and the reader may not lift that: the engine refuses to rewrite it.</summary>
    public static bool IsLockedAgainstChange(PdfDocument document) =>
        document.Security is { OpenedAsOwner: false, Permissions: not PdfPermissions.All };
}
