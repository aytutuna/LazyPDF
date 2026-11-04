using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>
/// What a visible signature shows: text, and a picture or ink on the left when there is one. Without
/// a rectangle on the request none of it is drawn.
/// </summary>
public sealed record SignatureLook
{
    /// <summary>The text, lines split at line feeds. Null writes the signer's name, date, reason and location; empty writes none.</summary>
    public string? Text { get; init; }

    public string FontFamily { get; init; } = "Helvetica";

    /// <summary>A picture of the signature as a JPEG; used before <see cref="Image"/>.</summary>
    public byte[]? Jpeg { get; init; }

    public PdfRgbaImage? Image { get; init; }

    /// <summary>Strokes of a drawn signature, points in the unit square with y up. Drawn when there is no picture.</summary>
    public IReadOnlyList<IReadOnlyList<(double X, double Y)>>? Ink { get; init; }
}

/// <summary>
/// A signature to apply: with whom, where, and in which format. <see cref="Time"/> is the caller's
/// clock. The certificate needs its private key unless <see cref="Signer"/> signs for it.
/// </summary>
public sealed record PdfSignRequest(X509Certificate2 Certificate, DateTimeOffset Time)
{
    /// <summary>Signs the digest for a key held elsewhere; the certificate then needs no private key.</summary>
    public PdfHashSigner? Signer { get; init; }

    /// <summary>Intermediate certificates to embed; the chain the system can build is used when empty.</summary>
    public IReadOnlyList<X509Certificate2> Chain { get; init; } = [];

    public SignatureFormat Format { get; init; } = SignatureFormat.CadesDetached;

    /// <summary>SHA-256, SHA-384 or SHA-512.</summary>
    public HashAlgorithmName Digest { get; init; } = HashAlgorithmName.SHA256;

    /// <summary>An empty signature field to sign; null makes a new field named "Signature1" and so on.</summary>
    public string? FieldName { get; init; }

    /// <summary>Page of a new field, from 0.</summary>
    public int PageIndex { get; init; }

    /// <summary>Where a new field sits (user space). Null makes it invisible; a field that exists keeps its own rectangle.</summary>
    public PdfRect? Rect { get; init; }

    public SignatureLook? Look { get; init; }

    /// <summary>The /Name entry; the certificate's common name when null.</summary>
    public string? Name { get; init; }

    public string? Reason { get; init; }
    public string? Location { get; init; }
    public string? ContactInfo { get; init; }

    /// <summary>Certifies the file (/DocMDP): the first signature only.</summary>
    public CertificationLevel Certify { get; init; }

    public FieldLock? Lock { get; init; }

    /// <summary>Adds an RFC 3161 time stamp to the signature: PAdES B-T.</summary>
    public TimestampSettings? Timestamp { get; init; }

    /// <summary>
    /// B-B by default. T needs <see cref="Timestamp"/>; LT also adds /DSS with the revocation data and LTA a
    /// document time stamp after it, both fetched through the transport of <see cref="Timestamp"/>.
    /// </summary>
    public PadesLevel Level { get; init; } = PadesLevel.B;

    public IFontSource? Fonts { get; init; }

    /// <summary>Bytes kept for the signature; 0 works it out from the certificates. A signature that does not fit is retried with more room.</summary>
    public int ReserveBytes { get; init; }
}
