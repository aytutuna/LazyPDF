using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Certificates;

/// <summary>What the user picked in the panel.</summary>
/// <param name="Field">An empty signature field of the file; null for a new one or none.</param>
/// <param name="Rect">The box of a new visible signature in user space; null with no field makes it invisible.</param>
/// <param name="TimestampUrl">Null or empty for no time stamp.</param>
/// <param name="LongTerm">Adds the revocation data (PAdES B-LT); needs a time stamp.</param>
internal sealed record SignChoices(X509Certificate2 Certificate, string? Field, int Page, PdfRect? Rect, string Reason, string Location,
    CertificationLevel Certify, string? TimestampUrl, bool LongTerm);

internal static class CertificateSigning
{
    public static PdfSignRequest Request(SignChoices choices, ISignatureTransport transport, IFontSource fonts, DateTimeOffset now)
    {
        var stamp = choices.TimestampUrl is { Length: > 0 } url ? new TimestampSettings(transport, url) : null;
        return new PdfSignRequest(choices.Certificate, now)
        {
            FieldName = choices.Field,
            PageIndex = choices.Page,
            Rect = choices.Rect,
            Reason = Blank(choices.Reason),
            Location = Blank(choices.Location),
            Certify = choices.Certify,
            Timestamp = stamp,
            Level = stamp is null ? PadesLevel.B : choices.LongTerm ? PadesLevel.LT : PadesLevel.T,
            Fonts = fonts,
        };
    }

    /// <summary>
    /// Signs the session's file. A step that fails or is cancelled leaves nothing of itself behind: what it had added
    /// but not committed is dropped, so the file is never left holding a signature that was not finished.
    /// </summary>
    public static void Sign(PdfEditSession session, SignChoices choices, ISignatureTransport transport, IFontSource fonts, DateTimeOffset now) =>
        DropOnFailure(session, () => PdfSigner.Sign(session, Request(choices, transport, fonts, now)));

    public static void AddValidation(PdfEditSession session, ISignatureTransport transport, DateTimeOffset now) =>
        DropOnFailure(session, () => PdfLongTermValidation.Add(session, transport, now));

    /// <summary>Whether every signature of the file now has proof from the certificate servers that its certificates were not withdrawn.</summary>
    public static bool RevocationCovered(byte[] file, VerifyOptions options) =>
        PdfSignatureVerifier.Verify(file, options).Where(r => r.Certificate is not null).All(r => r.RevocationChecked);

    /// <summary>Why the file may not be signed; null when it may. A field of the file needs less than a new one.</summary>
    public static Problem? Refusal(PdfDocument document, bool newField)
    {
        if (document.Security is not { OpenedAsOwner: false } security) return null;
        var permissions = security.Permissions;
        bool allowed = newField
            ? permissions.HasFlag(PdfPermissions.Annotate) && permissions.HasFlag(PdfPermissions.Modify)
            : permissions.HasFlag(PdfPermissions.FillForms) || permissions.HasFlag(PdfPermissions.Annotate);
        return allowed ? null : new Problem(Loc.T("This file cannot be signed"), Loc.T("Its permissions do not allow it. Open it with the owner password."));
    }

    public static bool IsWebAddress(string text) =>
        Uri.TryCreate(text.Trim(), UriKind.Absolute, out var address) && address.Scheme is "http" or "https";

    /// <summary>The empty signature fields of a file, by name.</summary>
    public static IReadOnlyList<string> EmptyFields(PdfDocument document) =>
        [.. PdfForm.Read(document).Fields.Where(f => f.Kind == FieldKind.Signature && !f.IsSigned).Select(f => f.Name)];

    private static void DropOnFailure(PdfEditSession session, Action work)
    {
        bool done = false;
        try
        {
            work();
            done = true;
        }
        finally
        {
            if (!done) session.Discard();
        }
    }

    private static string? Blank(string text) => text.Trim() is { Length: > 0 } trimmed ? trimmed : null;
}
