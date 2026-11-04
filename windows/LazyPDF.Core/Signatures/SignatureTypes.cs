using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>What a person should make of a signature.</summary>
public enum SignatureVerdict
{
    /// <summary>Intact, the signer is trusted, and the file is unchanged or changed only as the signer allowed.</summary>
    Valid,

    /// <summary>Intact, but the signer's certificate does not lead to a trusted root, was not valid at signing time or is revoked.</summary>
    ValidButUntrusted,

    /// <summary>The signed part is intact, but the file was changed afterwards in ways that are not allowed.</summary>
    ChangedAfterSigning,

    /// <summary>The digest or the signature does not match, or the signature does not cover the file as it must.</summary>
    Broken,

    /// <summary>It could not be checked: a format or algorithm Lazy PDF does not read, or a file it cannot make sense of.</summary>
    Unknown,
}

public enum SignatureKind
{
    Approval,

    /// <summary>The first signature, with a /DocMDP rule on what may change afterwards.</summary>
    Certification,

    /// <summary>A time stamp over the document (ETSI.RFC3161) with no signer.</summary>
    DocumentTimestamp,
}

/// <summary>The signature format: /SubFilter adbe.pkcs7.detached or ETSI.CAdES.detached.</summary>
public enum SignatureFormat
{
    Pkcs7Detached,
    CadesDetached,
}

/// <summary>The /DocMDP access permission (ISO 32000-1 12.8.2.2) a certification signature grants.</summary>
public enum CertificationLevel
{
    None = 0,
    NoChanges = 1,
    FormFill = 2,
    Annotate = 3,
}

/// <summary>PAdES baseline level of a CAdES signature (ETSI EN 319 142-1).</summary>
public enum PadesLevel
{
    /// <summary>Not a CAdES signature, or one that does not reach B-B.</summary>
    None,
    B,
    T,
    LT,
    LTA,
}

public enum SignatureProblem
{
    UnsupportedFormat,
    BadByteRange,
    DigestMismatch,
    BadSignature,
    NoCertificate,
    UntrustedSigner,
    CertificateNotValid,
    CertificateRevoked,
    ChangedAfterSigning,
    DamagedStructure,
    TimestampInvalid,
    WeakDigest,
}

/// <summary>Signs a digest for a key that is not in this process: a smart card, a token, a remote service.</summary>
/// <param name="hash">The digest to sign, as <see cref="RSA.SignHash"/> and <see cref="ECDsa.SignHash"/> take it.</param>
/// <param name="algorithm">The algorithm the digest was made with.</param>
/// <returns>An RSA PKCS#1 v1.5 signature, or an ECDSA signature as r followed by s (IEEE P1363).</returns>
public delegate byte[] PdfHashSigner(byte[] hash, HashAlgorithmName algorithm);

/// <summary>Posting and fetching bytes, which Core never does itself: time stamps, OCSP, CRLs, issuer certificates.</summary>
public interface ISignatureTransport
{
    /// <summary>The response body of a POST, or null when the request failed.</summary>
    byte[]? Post(string url, string contentType, byte[] body);

    /// <summary>The body of a GET, or null when the request failed.</summary>
    byte[]? Get(string url);
}

/// <summary>Where to get an RFC 3161 time stamp.</summary>
public sealed record TimestampSettings(ISignatureTransport Transport, string? Url = null)
{
    public HashAlgorithmName Digest { get; init; } = HashAlgorithmName.SHA256;
}

/// <summary>What the signer of a field is bound to when a later signature fills it in (ISO 32000-1 12.7.4.5).</summary>
public enum FieldLockAction
{
    All,
    Include,
    Exclude,
}

/// <summary>Fields locked once this signature is applied. <see cref="Fields"/> are field names.</summary>
public sealed record FieldLock(FieldLockAction Action, IReadOnlyList<string> Fields);

/// <summary>What changed since a signature, by kind (see <see cref="SignatureText.Describe"/>).</summary>
public enum SignatureChangeKind
{
    FormFill,
    Signature,
    ValidationData,
    Comment,
    Metadata,
    PageContent,
    PageStructure,
    Form,
    Other,

    /// <summary>What follows the signed bytes cannot be read exactly, so nothing about it can be judged.</summary>
    Unreadable,
}

/// <summary>One difference between the signed revision and a later one. <paramref name="Page"/> is 0-based, -1 when no page is involved.</summary>
public sealed record SignatureChange(SignatureChangeKind Kind, int Object, int Page, string? Field, bool Allowed);

/// <summary>The differences between the signed revision and the file as it is.</summary>
public sealed record SignatureChangeReport(IReadOnlyList<SignatureChange> Changes, int RevisionsAfter)
{
    public static SignatureChangeReport None { get; } = new([], 0);

    public bool IsEmpty => Changes.Count == 0;

    public bool AllAllowed => Changes.All(c => c.Allowed);

    public IEnumerable<SignatureChange> NotAllowed => Changes.Where(c => !c.Allowed);
}

/// <summary>One signature (or document time stamp) found in a file and what is known of it.</summary>
public sealed record SignatureReport
{
    public int Index { get; init; }

    /// <summary>The form field the signature sits in, null when no field of the current file holds it.</summary>
    public string? FieldName { get; init; }

    public SignatureKind Kind { get; init; }

    public string SubFilter { get; init; } = "";
    public SignatureVerdict Verdict { get; init; }
    public IReadOnlyList<SignatureProblem> Problems { get; init; } = [];

    /// <summary>The signer's common name; the /Name entry when the certificate has none. Null for a time stamp.</summary>
    public string? SignerName { get; init; }

    public X509Certificate2? Certificate { get; init; }
    public string? Reason { get; init; }
    public string? Location { get; init; }

    /// <summary>When the signer says it was signed (the signing-time attribute, else /M). Not proof of anything without a time stamp.</summary>
    public DateTimeOffset? SigningTime { get; init; }

    /// <summary>The time of a valid RFC 3161 token, in the signature or, for a document time stamp, the token itself.</summary>
    public DateTimeOffset? TimestampTime { get; init; }

    /// <summary>The time used to judge the certificates: the time stamp, else the signer's claim, else the time the caller gave.</summary>
    public DateTimeOffset? TimeUsed { get; init; }

    public CertificationLevel Certification { get; init; }
    public PadesLevel Level { get; init; }

    /// <summary>The byte range covers the file to its end.</summary>
    public bool CoversWholeFile { get; init; }

    /// <summary>The revision (from 1) the signature closes; 0 when that is not known.</summary>
    public int Revision { get; init; }

    public SignatureChangeReport Changes { get; init; } = SignatureChangeReport.None;

    /// <summary>True when OCSP or CRL data from the signature or the /DSS shows no certificate of the chain revoked.</summary>
    public bool RevocationChecked { get; init; }

    /// <summary>One plain line a person can read.</summary>
    public string Sentence => SignatureText.Sentence(this);
}

/// <summary>What to trust when verifying.</summary>
public sealed record VerifyOptions
{
    /// <summary>Roots (or intermediates) the caller trusts.</summary>
    public IReadOnlyList<X509Certificate2> TrustAnchors { get; init; } = [];

    /// <summary>Also trust the roots of the system store.</summary>
    public bool UseSystemStore { get; init; }

    /// <summary>The time used for certificates when a signature carries no time of its own; the caller's clock.</summary>
    public DateTimeOffset? Now { get; init; }

    public string? Password { get; init; }
}
