using System.Globalization;

namespace LazyPDF.Core;

// User-visible words of this layer, in one place until Loc.T exists.
public static class SignatureText
{
    public const string NoPrivateKey = "This certificate has no private key. Choose another one or sign with a token.";
    public const string NotCertifiable = "Only the first signature of a file can certify it. Sign without certifying.";
    public const string CertifiedClosed = "This file is certified so that nothing may change. Another signature would break that.";
    public const string FieldLocked = "An earlier signature locked this field. Choose another one.";
    public const string FieldTaken = "This field is already signed. Choose another one.";
    public const string NoFont = "No font can draw the signature text. Choose another font.";
    public const string NoPage = "The page is not in the document.";
    public const string NoTimestamp = "The time stamp server gave no answer. Try again later.";
    public const string NoTimestampServer = "This signature needs a time stamp server.";
    public const string NoRoom = "The signature does not fit in the space kept for it.";
    public const string SeedFormat = "The field asks for a different signature format.";
    public const string SeedDigest = "The field asks for a different digest.";
    public const string SeedReason = "The field asks for one of its listed reasons.";
    public const string SeedCertificate = "The field asks for another certificate.";
    public const string SeedCertification = "The field asks for another certification level.";
    public const string SeedUnsupported = "The field asks for something Lazy PDF cannot do.";
    public const string NotSigned = "The file has no signature to add validation data to.";

    // The wording of the visible signature.
    public const string SignedBy = "Digitally signed by";
    public const string DatePrefix = "Date:";
    public const string ReasonPrefix = "Reason:";
    public const string LocationPrefix = "Location:";

    /// <summary>Six words at most.</summary>
    public static string Status(SignatureVerdict verdict) => verdict switch
    {
        SignatureVerdict.Valid => "Signature is valid",
        SignatureVerdict.ValidButUntrusted => "Signer is not trusted",
        SignatureVerdict.ChangedAfterSigning => "Changed after signing",
        SignatureVerdict.Broken => "Signature is not valid",
        _ => "Signature not checked",
    };

    /// <summary>One line a person can read.</summary>
    public static string Sentence(SignatureReport report)
    {
        string when = Date(report.TimestampTime ?? report.SigningTime);
        string who = report.SignerName ?? "an unknown signer";
        bool stamp = report.Kind == SignatureKind.DocumentTimestamp;
        string head = stamp ? $"Time stamped on {when}." : $"Signed by {who} on {when}.";
        if (when.Length == 0) head = stamp ? "Time stamped." : $"Signed by {who}.";
        return report.Verdict switch
        {
            SignatureVerdict.Valid when report.Changes.IsEmpty => head + " Not changed since.",
            SignatureVerdict.Valid => head + " Changed only as the signer allowed.",
            SignatureVerdict.ValidButUntrusted => head + (report.Changes.IsEmpty ? " " : " Changed only as allowed. ") + "The signer is not trusted.",
            SignatureVerdict.ChangedAfterSigning => head + " Changed since.",
            SignatureVerdict.Broken => stamp ? "The time stamp is not valid." : $"The signature by {who} is not valid.",
            _ => "This signature could not be checked.",
        };
    }

    /// <summary>What is wrong, as a title.</summary>
    public static string Title(SignatureProblem problem) => problem switch
    {
        SignatureProblem.UnsupportedFormat => "Signature format not supported",
        SignatureProblem.BadByteRange => "Signature does not cover the file",
        SignatureProblem.DigestMismatch => "File does not match the signature",
        SignatureProblem.BadSignature => "Signature is damaged",
        SignatureProblem.NoCertificate => "Signer's certificate is missing",
        SignatureProblem.UntrustedSigner => "Signer is not trusted",
        SignatureProblem.CertificateNotValid => "Certificate was not valid when signing",
        SignatureProblem.CertificateRevoked => "Certificate was revoked",
        SignatureProblem.ChangedAfterSigning => "File changed after signing",
        SignatureProblem.DamagedStructure => "File structure is damaged",
        SignatureProblem.TimestampInvalid => "Time stamp is not valid",
        _ => "Signature uses a weak digest",
    };

    /// <summary>What to do about it.</summary>
    public static string Advice(SignatureProblem problem) => problem switch
    {
        SignatureProblem.UnsupportedFormat => "Check the file with the program that signed it.",
        SignatureProblem.BadByteRange => "Do not rely on this signature. Ask for a new copy.",
        SignatureProblem.DigestMismatch => "Do not rely on this file. Ask for a new copy.",
        SignatureProblem.BadSignature => "Do not rely on this signature. Ask for a new copy.",
        SignatureProblem.NoCertificate => "Ask the signer to sign again with the certificate included.",
        SignatureProblem.UntrustedSigner => "Trust the signer's certificate only after checking it with them.",
        SignatureProblem.CertificateNotValid => "Check the date on the signature and the certificate.",
        SignatureProblem.CertificateRevoked => "Do not rely on this signature.",
        SignatureProblem.ChangedAfterSigning => "Open the signed version from the file's history.",
        SignatureProblem.DamagedStructure => "Open the signed version from the file's history.",
        SignatureProblem.TimestampInvalid => "Treat the signing time as the signer's claim.",
        _ => "Ask the signer to sign again with SHA-256.",
    };

    /// <summary>A change in words.</summary>
    public static string Describe(SignatureChange change)
    {
        string where = change.Field is { } field ? $" in field {field}" : change.Page >= 0 ? $" on page {change.Page + 1}" : "";
        return change.Kind switch
        {
            SignatureChangeKind.FormFill => "Form filled" + where,
            SignatureChangeKind.Signature => "Signature added" + where,
            SignatureChangeKind.ValidationData => "Validation data added",
            SignatureChangeKind.Comment => "Comment changed" + where,
            SignatureChangeKind.Metadata => "Document information changed",
            SignatureChangeKind.PageContent => "Page content changed" + where,
            SignatureChangeKind.PageStructure => "Pages changed" + where,
            SignatureChangeKind.Form => "Form changed" + where,
            _ => "Document changed" + where,
        };
    }

    private static string Date(DateTimeOffset? time) =>
        time is { } t ? t.ToString("d MMM yyyy", CultureInfo.InvariantCulture) : "";
}
