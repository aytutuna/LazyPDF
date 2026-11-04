using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

/// <summary>Certificates and revocation data a file carries for its signatures: the /DSS, and what a signature archived in itself.</summary>
internal sealed class ValidationData
{
    private const int MaxStreams = 4096;

    public List<X509Certificate2> Certificates { get; } = [];
    public List<OcspResponse> Ocsps { get; } = [];
    public List<Crl> Crls { get; } = [];

    public static ValidationData ReadDss(PdfDocument document)
    {
        var data = new ValidationData();
        if (document.Dict(document.Catalog, "DSS") is not { } dss) return data;
        foreach (var bytes in Streams(document, dss, "Certs"))
        {
            try { data.Certificates.Add(X509CertificateLoader.LoadCertificate(bytes)); }
            catch (CryptographicException) { }
        }
        foreach (var bytes in Streams(document, dss, "OCSPs"))
        {
            if (OcspResponse.Parse(bytes) is { } ocsp) data.Ocsps.Add(ocsp);
        }
        foreach (var bytes in Streams(document, dss, "CRLs"))
        {
            if (Crl.Parse(bytes) is { } crl) data.Crls.Add(crl);
        }
        return data;
    }

    private static IEnumerable<byte[]> Streams(PdfDocument document, PdfDictionary dss, string key)
    {
        if (document.Array(dss, key) is not { } array) yield break;
        foreach (var item in array.Items.Take(MaxStreams))
        {
            if (document.Resolve(item) is not PdfStream stream) continue;
            byte[]? bytes = null;
            try { bytes = document.Data(stream); }
            catch (PdfReadException) { }
            if (bytes is not null) yield return bytes;
        }
    }

    /// <summary>adbe-revocationInfoArchival: CRLs and OCSP responses the signer put in the signature itself.</summary>
    public void ReadArchival(CmsSignature cms)
    {
        if (!cms.Attributes.TryGetValue(Oids.RevocationArchival, out var values)) return;
        foreach (byte[] value in values)
        {
            try
            {
                var info = new AsnReader(value, AsnEncodingRules.BER).ReadSequence();
                while (info.HasData)
                {
                    var tag = info.PeekTag();
                    var list = info.ReadSequence(tag).ReadSequence();
                    while (list.HasData)
                    {
                        byte[] der = list.ReadEncodedValue().ToArray();
                        if (tag.TagValue == 0 && Crl.Parse(der) is { } crl) Crls.Add(crl);
                        else if (tag.TagValue == 1 && OcspResponse.Parse(der) is { } ocsp) Ocsps.Add(ocsp);
                    }
                }
            }
            catch (AsnContentException)
            {
                // Archived data that does not read adds nothing.
            }
        }
    }

    /// <summary>What the data says of <paramref name="certificate"/>; a revocation is reported with its time.</summary>
    public (RevocationState State, DateTimeOffset? At) Check(X509Certificate2 certificate, X509Certificate2 issuer)
    {
        var state = RevocationState.NoData;
        foreach (var ocsp in Ocsps)
        {
            var (s, revokedAt, _) = ocsp.About(certificate, issuer);
            if (s == RevocationState.Revoked) return (s, revokedAt);
            if (s == RevocationState.Good) state = s;
        }
        foreach (var crl in Crls)
        {
            var (s, revokedAt) = crl.About(certificate, issuer);
            if (s == RevocationState.Revoked) return (s, revokedAt);
            if (s == RevocationState.Good && state == RevocationState.NoData) state = s;
        }
        return (state, null);
    }
}

/// <summary>A certificate chain built for a signature, and whether it can be trusted at a given time.</summary>
internal sealed record TrustResult(bool Trusted, bool TimeValid, IReadOnlyList<X509Certificate2> Chain);

internal static class CertificateTrust
{
    private const X509ChainStatusFlags Harmless = X509ChainStatusFlags.NoError | X509ChainStatusFlags.NotTimeValid
        | X509ChainStatusFlags.RevocationStatusUnknown | X509ChainStatusFlags.OfflineRevocation;

    public static TrustResult Evaluate(X509Certificate2 certificate, IEnumerable<X509Certificate2> extra, DateTimeOffset? time, VerifyOptions options)
    {
        var certificates = extra.ToList();
        var result = Build(certificate, certificates, time, options.TrustAnchors, system: false);
        if (!result.Trusted && options.UseSystemStore)
        {
            var viaSystem = Build(certificate, [.. certificates, .. options.TrustAnchors], time, [], system: true);
            if (viaSystem.Trusted) return viaSystem;
        }
        return result;
    }

    private static TrustResult Build(X509Certificate2 certificate, List<X509Certificate2> extra, DateTimeOffset? time, IReadOnlyList<X509Certificate2> anchors, bool system)
    {
        using var chain = new X509Chain();
        var policy = chain.ChainPolicy;
        policy.RevocationMode = X509RevocationMode.NoCheck;
        policy.DisableCertificateDownloads = true;
        if (time is { } t) policy.VerificationTime = t.UtcDateTime;
        policy.TrustMode = system ? X509ChainTrustMode.System : X509ChainTrustMode.CustomRootTrust;
        foreach (var anchor in anchors) policy.CustomTrustStore.Add(anchor);
        foreach (var c in extra) policy.ExtraStore.Add(c);
        chain.Build(certificate);

        var statuses = chain.ChainStatus.Aggregate(X509ChainStatusFlags.NoError, (all, s) => all | s.Status);
        var elements = chain.ChainElements.Select(e => X509CertificateLoader.LoadCertificate(e.Certificate.RawData)).ToList();
        return new TrustResult((statuses & ~Harmless) == 0, (statuses & X509ChainStatusFlags.NotTimeValid) == 0, elements);
    }
}
