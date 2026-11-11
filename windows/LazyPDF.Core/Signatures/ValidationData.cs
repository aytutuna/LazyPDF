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
            catch (Exception e) when (e is AsnContentException or ArgumentException)
            {
                // Archived data that does not read adds nothing.
            }
        }
    }

    /// <summary>What the data says of <paramref name="certificate"/>; a revocation is reported with its time. "Good" counts only when the data holds for <paramref name="time"/>, when there is one.</summary>
    public (RevocationState State, DateTimeOffset? At) Check(X509Certificate2 certificate, X509Certificate2 issuer, DateTimeOffset? time = null)
    {
        var state = RevocationState.NoData;
        foreach (var ocsp in Ocsps)
        {
            var (s, revokedAt, _) = ocsp.About(certificate, issuer, time);
            if (s == RevocationState.Revoked) return (s, revokedAt);
            if (s == RevocationState.Good) state = s;
        }
        foreach (var crl in Crls)
        {
            var (s, revokedAt) = crl.About(certificate, issuer, time);
            if (s == RevocationState.Revoked) return (s, revokedAt);
            if (s == RevocationState.Good && state == RevocationState.NoData) state = s;
        }
        return (state, null);
    }
}

/// <summary>A certificate chain built for a signature, and whether it can be trusted at a given time.</summary>
internal sealed record TrustResult(bool Trusted, bool TimeValid, IReadOnlyList<X509Certificate2> Chain, bool Partial = false);

internal static class CertificateTrust
{
    private const X509ChainStatusFlags Harmless = X509ChainStatusFlags.NoError | X509ChainStatusFlags.NotTimeValid
        | X509ChainStatusFlags.RevocationStatusUnknown | X509ChainStatusFlags.OfflineRevocation;

    private static readonly DateTime FileTimeEpoch = new(1601, 1, 1, 0, 0, 0, DateTimeKind.Utc);
    private const int MaxFetches = 4;
    private const string TimeStamping = "1.3.6.1.5.5.7.3.8";
    private static readonly string[] SigningPurposes =
    [
        "1.3.6.1.5.5.7.3.4", // email protection, which PDF signers have long carried
        "1.2.840.113583.1.1.5", // Adobe PDF signing
        "1.3.6.1.4.1.311.10.3.12", // Microsoft document signing
        "2.5.29.37.0", // any purpose
    ];

    /// <summary>The chain of <paramref name="certificate"/>, trusted only when it is also meant for the job: signing documents, or for a time stamp authority <paramref name="timestamp"/>.</summary>
    public static TrustResult Evaluate(X509Certificate2 certificate, IEnumerable<X509Certificate2> extra, DateTimeOffset? time, VerifyOptions options, bool timestamp = false)
    {
        var certificates = extra.ToList();
        var result = Settle(certificate, certificates, time, options);
        for (int round = 0; round < MaxFetches && !result.Trusted && result.Partial && options.Transport is { } transport; round++)
        {
            if (CertificateLinks.FetchIssuer(result.Chain[^1], transport) is not { } issuer
                || certificates.Any(c => c.Thumbprint == issuer.Thumbprint)) break;
            certificates.Add(issuer);
            result = Settle(certificate, certificates, time, options);
        }
        return Suits(certificate, timestamp) ? result : result with { Trusted = false };
    }

    private static TrustResult Settle(X509Certificate2 certificate, List<X509Certificate2> certificates, DateTimeOffset? time, VerifyOptions options)
    {
        // X509Chain keeps going past an anchor that is not self-signed, so a signer the caller trusts by itself is settled here.
        var at = time ?? DateTimeOffset.UtcNow;
        var result = options.TrustAnchors.Any(a => a.RawData.AsSpan().SequenceEqual(certificate.RawData))
            ? new TrustResult(true, certificate.NotBefore <= at && at <= certificate.NotAfter, [certificate])
            : Build(certificate, certificates, time, options.TrustAnchors, system: false);
        if (!result.Trusted && options.UseSystemStore)
        {
            var viaSystem = Build(certificate, [.. certificates, .. options.TrustAnchors], time, [], system: true);
            result = viaSystem.Trusted ? viaSystem : result with { Partial = result.Partial || viaSystem.Partial };
        }
        return result;
    }

    // RFC 5280 4.2.1.3 and 4.2.1.12; RFC 3161 2.3 asks a time stamp authority for the one purpose.
    // The extensions decode when read, and a certificate in a file may carry one that does not: it suits nothing.
    private static bool Suits(X509Certificate2 certificate, bool timestamp)
    {
        try
        {
            if (certificate.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault() is { } usage
                && (usage.KeyUsages & (X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.NonRepudiation)) == 0) return false;
            if (certificate.Extensions.OfType<X509EnhancedKeyUsageExtension>().FirstOrDefault() is not { } purposes) return !timestamp;
            var oids = purposes.EnhancedKeyUsages.Cast<Oid>().Select(o => o.Value).ToList();
            return timestamp ? oids.Contains(TimeStamping) : oids.Any(o => SigningPurposes.Contains(o));
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    private static TrustResult Build(X509Certificate2 certificate, List<X509Certificate2> extra, DateTimeOffset? time, IReadOnlyList<X509Certificate2> anchors, bool system)
    {
        using var chain = new X509Chain();
        var policy = chain.ChainPolicy;
        policy.RevocationMode = X509RevocationMode.NoCheck;
        policy.DisableCertificateDownloads = true;
        // Windows converts the time to a file time, which cannot hold a date before 1601; no certificate is valid then either.
        if (time is { } t) policy.VerificationTime = t.UtcDateTime < FileTimeEpoch ? FileTimeEpoch : t.UtcDateTime;
        policy.TrustMode = system ? X509ChainTrustMode.System : X509ChainTrustMode.CustomRootTrust;
        foreach (var anchor in anchors) policy.CustomTrustStore.Add(anchor);
        foreach (var c in extra) policy.ExtraStore.Add(c);
        chain.Build(certificate);

        var statuses = chain.ChainStatus.Aggregate(X509ChainStatusFlags.NoError, (all, s) => all | s.Status);
        var elements = chain.ChainElements.Select(e => X509CertificateLoader.LoadCertificate(e.Certificate.RawData)).ToList();
        return new TrustResult((statuses & ~Harmless) == 0, (statuses & X509ChainStatusFlags.NotTimeValid) == 0, elements, (statuses & X509ChainStatusFlags.PartialChain) != 0);
    }
}
