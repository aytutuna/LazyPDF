using System.Globalization;

namespace LazyPDF.Core;

public static class SignatureText
{
    public static string NoPrivateKey => Loc.T("This certificate has no private key. Choose another one or sign with a token.");
    public static string NotCertifiable => Loc.T("Only the first signature of a file can certify it. Sign without certifying.");
    public static string CertifiedClosed => Loc.T("This file is certified so that nothing may change. Another signature would break that.");
    public static string FieldLocked => Loc.T("An earlier signature locked this field. Choose another one.");
    public static string FieldTaken => Loc.T("This field is already signed. Choose another one.");
    public static string NoFont => Loc.T("No font can draw the signature text. Choose another font.");
    public static string NoPage => Loc.T("The page is not in the document.");
    public static string NoTimestamp => Loc.T("The time stamp server gave no answer. Try again later.");
    public static string NoTimestampServer => Loc.T("This signature needs a time stamp server.");
    public static string NoRoom => Loc.T("The signature does not fit in the space kept for it.");
    public static string SeedFormat => Loc.T("The field asks for a different signature format.");
    public static string SeedDigest => Loc.T("The field asks for a different digest.");
    public static string SeedReason => Loc.T("The field asks for one of its listed reasons.");
    public static string SeedCertificate => Loc.T("The field asks for another certificate.");
    public static string SeedCertification => Loc.T("The field asks for another certification level.");
    public static string SeedUnsupported => Loc.T("The field asks for something Lazy PDF cannot do.");
    public static string NotSigned => Loc.T("The file has no signature to add validation data to.");

    // The wording of the visible signature.
    public const string SignedBy = "Digitally signed by";
    public const string DatePrefix = "Date:";
    public const string ReasonPrefix = "Reason:";
    public const string LocationPrefix = "Location:";

    /// <summary>Six words at most.</summary>
    public static string Status(SignatureVerdict verdict) => verdict switch
    {
        SignatureVerdict.Valid => Loc.T("Signature is valid"),
        SignatureVerdict.ValidButUntrusted => Loc.T("Signer is not trusted"),
        SignatureVerdict.ChangedAfterSigning => Loc.T("Changed after signing"),
        SignatureVerdict.Broken => Loc.T("Signature is not valid"),
        _ => Loc.T("Signature not checked"),
    };

    /// <summary>One line a person can read.</summary>
    public static string Sentence(SignatureReport report)
    {
        string when = Date(report.TimestampTime ?? report.SigningTime);
        string who = report.SignerName ?? Loc.T("an unknown signer");
        bool stamp = report.Kind == SignatureKind.DocumentTimestamp;
        string head = when.Length == 0
            ? stamp ? Loc.T("Time stamped.") : Loc.T("Signed by {0}.", who)
            : stamp ? Loc.T("Time stamped on {0}.", when) : Loc.T("Signed by {0} on {1}.", who, when);
        return report.Verdict switch
        {
            SignatureVerdict.Valid when report.Changes.IsEmpty => head + " " + Loc.T("Not changed since."),
            SignatureVerdict.Valid => head + " " + Loc.T("Changed only as the signer allowed."),
            SignatureVerdict.ValidButUntrusted => head + " " + (report.Changes.IsEmpty ? "" : Loc.T("Changed only as allowed.") + " ") + Loc.T("The signer is not trusted."),
            SignatureVerdict.ChangedAfterSigning => head + " " + Loc.T("Changed since."),
            SignatureVerdict.Broken => stamp ? Loc.T("The time stamp is not valid.") : Loc.T("The signature by {0} is not valid.", who),
            _ => Loc.T("This signature could not be checked."),
        };
    }

    /// <summary>What is wrong, as a title.</summary>
    public static string Title(SignatureProblem problem) => problem switch
    {
        SignatureProblem.UnsupportedFormat => Loc.T("Signature format not supported"),
        SignatureProblem.BadByteRange => Loc.T("Signature does not cover the file"),
        SignatureProblem.DigestMismatch => Loc.T("File does not match the signature"),
        SignatureProblem.BadSignature => Loc.T("Signature is damaged"),
        SignatureProblem.NoCertificate => Loc.T("Signer's certificate is missing"),
        SignatureProblem.UntrustedSigner => Loc.T("Signer is not trusted"),
        SignatureProblem.CertificateNotValid => Loc.T("Certificate was not valid when signing"),
        SignatureProblem.CertificateRevoked => Loc.T("Certificate was revoked"),
        SignatureProblem.ChangedAfterSigning => Loc.T("File changed after signing"),
        SignatureProblem.DamagedStructure => Loc.T("File structure is damaged"),
        SignatureProblem.TimestampInvalid => Loc.T("Time stamp is not valid"),
        _ => Loc.T("Signature uses a weak digest"),
    };

    /// <summary>What to do about it.</summary>
    public static string Advice(SignatureProblem problem) => problem switch
    {
        SignatureProblem.UnsupportedFormat => Loc.T("Check the file with the program that signed it."),
        SignatureProblem.BadByteRange => Loc.T("Do not rely on this signature. Ask for a new copy."),
        SignatureProblem.DigestMismatch => Loc.T("Do not rely on this file. Ask for a new copy."),
        SignatureProblem.BadSignature => Loc.T("Do not rely on this signature. Ask for a new copy."),
        SignatureProblem.NoCertificate => Loc.T("Ask the signer to sign again with the certificate included."),
        SignatureProblem.UntrustedSigner => Loc.T("Trust the signer's certificate only after checking it with them."),
        SignatureProblem.CertificateNotValid => Loc.T("Check the date on the signature and the certificate."),
        SignatureProblem.CertificateRevoked => Loc.T("Do not rely on this signature."),
        SignatureProblem.ChangedAfterSigning => Loc.T("Open the signed version from the file's history."),
        SignatureProblem.DamagedStructure => Loc.T("Open the signed version from the file's history."),
        SignatureProblem.TimestampInvalid => Loc.T("Treat the signing time as the signer's claim."),
        _ => Loc.T("Ask the signer to sign again with SHA-256."),
    };

    /// <summary>A change in words.</summary>
    public static string Describe(SignatureChange change)
    {
        string where = change.Field is { } field ? Loc.T(" in field {0}", field) : change.Page >= 0 ? Loc.T(" on page {0}", change.Page + 1) : "";
        return change.Kind switch
        {
            SignatureChangeKind.FormFill => Loc.T("Form filled") + where,
            SignatureChangeKind.Signature => Loc.T("Signature added") + where,
            SignatureChangeKind.ValidationData => Loc.T("Validation data added"),
            SignatureChangeKind.Comment => Loc.T("Comment changed") + where,
            SignatureChangeKind.Metadata => Loc.T("Document information changed"),
            SignatureChangeKind.PageContent => Loc.T("Page content changed") + where,
            SignatureChangeKind.PageStructure => Loc.T("Pages changed") + where,
            SignatureChangeKind.Form => Loc.T("Form changed") + where,
            SignatureChangeKind.Unreadable => Loc.T("Added data cannot be checked"),
            _ => Loc.T("Document changed") + where,
        };
    }

    private static string Date(DateTimeOffset? time) =>
        time is { } t ? t.ToString("d MMM yyyy", CultureInfo.CurrentUICulture) : "";
}
