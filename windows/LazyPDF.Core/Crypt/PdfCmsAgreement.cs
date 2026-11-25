using System.Buffers.Binary;
using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

// The recipients EnvelopedCms cannot be asked for: a KeyAgreeRecipientInfo with ephemeral-static ECDH (RFC 5753),
// a key encryption key from the ANSI X9.63 KDF over the shared secret, and the content key under it by AES key
// wrap (RFC 3394). Written for P-256 and P-384 with AES-256 wrap and the curve's SHA-2 hash; read for P-256, P-384
// and P-521, SHA-1 to SHA-512 and any AES wrap. Content is AES-CBC. Entries are not matched to the certificate by
// name: the key wrap's integrity check says whether the key was the right one.
internal static class PdfCmsAgreement
{
    private const string EcPublicKey = "1.2.840.10045.2.1";
    private const string EnvelopedData = "1.2.840.113549.1.7.3";
    private const string Data = "1.2.840.113549.1.7.1";
    private const string Aes256Cbc = "2.16.840.1.101.3.4.1.42";
    private const string Aes256Wrap = "2.16.840.1.101.3.4.1.45";

    private static readonly Asn1Tag Context0 = new(TagClass.ContextSpecific, 0);
    private static readonly Asn1Tag Context1 = new(TagClass.ContextSpecific, 1);
    private static readonly Asn1Tag Context2 = new(TagClass.ContextSpecific, 2);

    // Curve, field size in bytes, and the KDF written for it (dhSinglePass-stdDH-sha256kdf-scheme and sha384).
    private static readonly Dictionary<string, (int Size, string Kdf)> Curves = new()
    {
        ["1.2.840.10045.3.1.7"] = (32, "1.3.132.1.11.1"),
        ["1.3.132.0.34"] = (48, "1.3.132.1.11.2"),
        ["1.3.132.0.35"] = (66, "1.3.132.1.11.3"),
    };

    // Standard and cofactor ECDH are the same on these curves.
    private static readonly Dictionary<string, HashAlgorithmName> Kdfs = new()
    {
        ["1.3.133.16.840.63.0.2"] = HashAlgorithmName.SHA1, ["1.3.133.16.840.63.0.3"] = HashAlgorithmName.SHA1,
        ["1.3.132.1.11.1"] = HashAlgorithmName.SHA256, ["1.3.132.1.14.1"] = HashAlgorithmName.SHA256,
        ["1.3.132.1.11.2"] = HashAlgorithmName.SHA384, ["1.3.132.1.14.2"] = HashAlgorithmName.SHA384,
        ["1.3.132.1.11.3"] = HashAlgorithmName.SHA512, ["1.3.132.1.14.3"] = HashAlgorithmName.SHA512,
    };

    private static readonly Dictionary<string, int> Wraps = new()
    {
        ["2.16.840.1.101.3.4.1.5"] = 16, ["2.16.840.1.101.3.4.1.25"] = 24, [Aes256Wrap] = 32,
    };

    private static readonly Dictionary<string, int> Ciphers = new()
    {
        ["2.16.840.1.101.3.4.1.2"] = 16, ["2.16.840.1.101.3.4.1.22"] = 24, [Aes256Cbc] = 32,
    };

    private static readonly byte[] WrapCheck = [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6];

    /// <summary>The curve's object identifier when the certificate holds an elliptic curve key, else null.</summary>
    public static string? CurveOf(X509Certificate2 certificate)
    {
        if (certificate.PublicKey.Oid.Value != EcPublicKey) return null;
        try
        {
            return new AsnReader(certificate.PublicKey.EncodedParameters!.RawData, AsnEncodingRules.DER).ReadObjectIdentifier();
        }
        catch (Exception e) when (e is AsnContentException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>A P-256 or P-384 key whose key usage, if stated, allows key agreement.</summary>
    public static bool CanProtect(X509Certificate2 certificate)
    {
        if (CurveOf(certificate) is not ("1.2.840.10045.3.1.7" or "1.3.132.0.34")) return false;
        var usage = certificate.Extensions.OfType<X509KeyUsageExtension>().FirstOrDefault();
        return usage is null || (usage.KeyUsages & X509KeyUsageFlags.KeyAgreement) != 0;
    }

    /// <summary>
    /// An EnvelopedData of <paramref name="content"/> for the certificate: a fresh AES-256 key wrapped under a key
    /// agreed with a fresh ephemeral key. The last three arguments exist for the tests.
    /// </summary>
    public static byte[] Seal(byte[] content, X509Certificate2 recipient, ECDiffieHellman? ephemeral = null,
                              byte[]? contentKey = null, byte[]? iv = null, bool writeCurve = true)
    {
        string curve = CurveOf(recipient)!;
        using var own = ephemeral is null ? ECDiffieHellman.Create(ECCurve.CreateFromValue(curve)) : null;
        ephemeral ??= own!;
        var (size, kdf) = Curves[curve];
        using var peer = PeerKey(curve, size, recipient.PublicKey.EncodedKeyValue.RawData);
        byte[] secret = ephemeral.DeriveRawSecretAgreement(peer.PublicKey);
        byte[] kek = DeriveKey(secret, Kdfs[kdf], Aes256Wrap, null, 32);
        contentKey ??= RandomNumberGenerator.GetBytes(32);
        iv ??= RandomNumberGenerator.GetBytes(16);
        byte[] wrapped = Wrap(kek, contentKey);

        using var aes = Aes.Create();
        aes.Key = contentKey;
        byte[] encrypted = aes.EncryptCbc(content, iv, PaddingMode.PKCS7);

        var q = ephemeral.ExportParameters(false).Q;
        byte[] point = [4, .. Pad(q.X!, size), .. Pad(q.Y!, size)];

        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            w.WriteObjectIdentifier(EnvelopedData);
            using (w.PushSequence(Context0))
            using (w.PushSequence())
            {
                w.WriteInteger(2);
                using (w.PushSetOf())
                using (w.PushSequence(Context1))
                {
                    w.WriteInteger(3);
                    using (w.PushSequence(Context0))
                    using (w.PushSequence(Context1))
                    {
                        using (w.PushSequence())
                        {
                            w.WriteObjectIdentifier(EcPublicKey);
                            if (writeCurve) w.WriteObjectIdentifier(curve);
                        }
                        w.WriteBitString(point);
                    }
                    using (w.PushSequence())
                    {
                        w.WriteObjectIdentifier(kdf);
                        using (w.PushSequence()) w.WriteObjectIdentifier(Aes256Wrap);
                    }
                    using (w.PushSequence())
                    using (w.PushSequence())
                    {
                        using (w.PushSequence())
                        {
                            w.WriteEncodedValue(recipient.IssuerName.RawData);
                            w.WriteInteger(recipient.SerialNumberBytes.Span);
                        }
                        w.WriteOctetString(wrapped);
                    }
                }
                using (w.PushSequence())
                {
                    w.WriteObjectIdentifier(Data);
                    using (w.PushSequence())
                    {
                        w.WriteObjectIdentifier(Aes256Cbc);
                        w.WriteOctetString(iv);
                    }
                    w.WriteOctetString(encrypted, Context0);
                }
            }
        }
        return w.Encode();
    }

    /// <summary>The content of an EnvelopedData that one of its key agreement entries opens with the certificate's private key; null when none does.</summary>
    public static byte[]? Unseal(byte[] stored, X509Certificate2 certificate)
    {
        try
        {
            using var key = PrivateKey(certificate);
            if (key is null) return null;
            var info = new AsnReader(stored, AsnEncodingRules.BER).ReadSequence();
            if (info.ReadObjectIdentifier() != EnvelopedData) return null;
            var data = info.ReadSequence(Context0).ReadSequence();
            data.ReadInteger();
            if (data.PeekTag().HasSameClassAndValue(Context0)) data.ReadEncodedValue();
            var recipients = data.ReadSetOf(true);
            var content = data.ReadSequence();
            if (content.ReadObjectIdentifier() != Data) return null;
            var cipher = content.ReadSequence();
            if (!Ciphers.TryGetValue(cipher.ReadObjectIdentifier(), out int keySize)) return null;
            byte[] iv = cipher.ReadOctetString();
            byte[] encrypted = content.ReadOctetString(Context0);

            while (recipients.HasData)
            {
                if (!recipients.PeekTag().HasSameClassAndValue(Context1))
                {
                    recipients.ReadEncodedValue();
                    continue;
                }
                var entry = recipients.ReadSequence(Context1);
                byte[]? kek;
                List<byte[]> wrappedKeys;
                try
                {
                    (kek, wrappedKeys) = AgreedKeys(entry, key);
                }
                catch (Exception e) when (e is AsnContentException or CryptographicException or ArgumentException or InvalidOperationException)
                {
                    // An entry on another curve or with a damaged point belongs to someone else; the next one may be ours.
                    continue;
                }
                foreach (byte[] wrapped in wrappedKeys)
                {
                    if (Unwrap(kek!, wrapped) is not { } contentKey || contentKey.Length != keySize) continue;
                    using var aes = Aes.Create();
                    aes.Key = contentKey;
                    return aes.DecryptCbc(encrypted, iv, PaddingMode.PKCS7);
                }
            }
        }
        catch (Exception e) when (e is AsnContentException or CryptographicException or ArgumentException or InvalidOperationException)
        {
        }
        return null;
    }

    // A key stored for signing only is not offered as an ECDH key by the system; its parameters are copied when it can be exported.
    private static ECDiffieHellman? PrivateKey(X509Certificate2 certificate)
    {
        if (certificate.GetECDiffieHellmanPrivateKey() is { } agreement) return agreement;
        using var signing = certificate.GetECDsaPrivateKey();
        return signing is null ? null : ECDiffieHellman.Create(signing.ExportParameters(true));
    }

    // The key encryption key of one KeyAgreeRecipientInfo and the encrypted keys that are under it.
    private static (byte[]? Kek, List<byte[]> Keys) AgreedKeys(AsnReader entry, ECDiffieHellman own)
    {
        var keys = new List<byte[]>();
        entry.ReadInteger();
        var originator = entry.ReadSequence(Context0);
        if (!originator.PeekTag().HasSameClassAndValue(Context1)) return (null, keys);
        var originatorKey = originator.ReadSequence(Context1);
        // RFC 5753 3.1.1 leaves the parameters out (OpenSSL) or writes NULL (BouncyCastle); the curve is then the recipient's own.
        string? stated = ReadCurve(originatorKey.ReadSequence());
        string? curve = stated ?? OwnCurve(own);
        byte[] point = originatorKey.ReadBitString(out _);
        byte[]? ukm = null;
        if (entry.PeekTag().HasSameClassAndValue(Context1)) ukm = entry.ReadSequence(Context1).ReadOctetString();
        var algorithm = entry.ReadSequence();
        string kdf = algorithm.ReadObjectIdentifier();
        string wrap = algorithm.ReadSequence().ReadObjectIdentifier();
        if (curve is null || !Curves.TryGetValue(curve, out var parameters) || !Kdfs.TryGetValue(kdf, out var hash) || !Wraps.TryGetValue(wrap, out int length))
            return (null, keys);

        using var peer = PeerKey(curve, parameters.Size, point);
        byte[] kek = DeriveKey(own.DeriveRawSecretAgreement(peer.PublicKey), hash, wrap, ukm, length);
        var list = entry.ReadSequence();
        while (list.HasData)
        {
            var item = list.ReadSequence();
            item.ReadEncodedValue();
            keys.Add(item.ReadOctetString());
        }
        return (kek, keys);
    }

    private static string? ReadCurve(AsnReader algorithm)
    {
        if (algorithm.ReadObjectIdentifier() != EcPublicKey) throw new CryptographicException();
        return algorithm.HasData && algorithm.PeekTag().HasSameClassAndValue(Asn1Tag.ObjectIdentifier) ? algorithm.ReadObjectIdentifier() : null;
    }

    private static string? OwnCurve(ECDiffieHellman key) =>
        key.KeySize switch { 256 => "1.2.840.10045.3.1.7", 384 => "1.3.132.0.34", 521 => "1.3.132.0.35", _ => null };

    private static ECDiffieHellman PeerKey(string curve, int size, byte[] point)
    {
        if (point.Length != 1 + 2 * size || point[0] != 4) throw new CryptographicException("The point is not an uncompressed one.");
        return ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.CreateFromValue(curve),
            Q = new ECPoint { X = point[1..(1 + size)], Y = point[(1 + size)..] },
        });
    }

    // ANSI X9.63 key derivation: hash of the secret, a 32-bit counter from 1 and the ECC-CMS-SharedInfo of RFC 5753 7.2.
    private static byte[] DeriveKey(byte[] secret, HashAlgorithmName hash, string wrap, byte[]? ukm, int length)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            using (w.PushSequence()) w.WriteObjectIdentifier(wrap);
            if (ukm is not null)
                using (w.PushSequence(Context0)) w.WriteOctetString(ukm);
            using (w.PushSequence(Context2))
            {
                byte[] bits = new byte[4];
                BinaryPrimitives.WriteInt32BigEndian(bits, length * 8);
                w.WriteOctetString(bits);
            }
        }
        byte[] info = w.Encode();

        var output = new List<byte>();
        for (uint counter = 1; output.Count < length; counter++)
        {
            byte[] input = new byte[secret.Length + 4 + info.Length];
            secret.CopyTo(input, 0);
            BinaryPrimitives.WriteUInt32BigEndian(input.AsSpan(secret.Length), counter);
            info.CopyTo(input, secret.Length + 4);
            output.AddRange(HashData(hash, input));
        }
        return [.. output.Take(length)];
    }

    private static byte[] HashData(HashAlgorithmName hash, byte[] input) =>
        hash.Name switch
        {
            "SHA1" => SHA1.HashData(input),
            "SHA256" => SHA256.HashData(input),
            "SHA384" => SHA384.HashData(input),
            _ => SHA512.HashData(input),
        };

    private static byte[] Pad(byte[] value, int size) => value.Length == size ? value : [.. new byte[size - value.Length], .. value];

    // RFC 3394.
    internal static byte[] Wrap(byte[] kek, byte[] key)
    {
        int n = key.Length / 8;
        byte[] a = [.. WrapCheck];
        byte[][] r = Enumerable.Range(0, n).Select(i => key[(8 * i)..(8 * i + 8)]).ToArray();
        using var aes = Aes.Create();
        aes.Key = kek;
        for (int j = 0; j < 6; j++)
            for (int i = 0; i < n; i++)
            {
                byte[] b = aes.EncryptEcb([.. a, .. r[i]], PaddingMode.None);
                a = b[..8];
                r[i] = b[8..];
                ulong t = (ulong)(n * j + i + 1);
                for (int k = 0; k < 8; k++) a[7 - k] ^= (byte)(t >> (8 * k));
            }
        return [.. a, .. r.SelectMany(x => x)];
    }

    internal static byte[]? Unwrap(byte[] kek, byte[] wrapped)
    {
        if (wrapped.Length < 24 || wrapped.Length % 8 != 0) return null;
        int n = wrapped.Length / 8 - 1;
        byte[] a = wrapped[..8];
        byte[][] r = Enumerable.Range(0, n).Select(i => wrapped[(8 * (i + 1))..(8 * (i + 2))]).ToArray();
        using var aes = Aes.Create();
        aes.Key = kek;
        for (int j = 5; j >= 0; j--)
            for (int i = n - 1; i >= 0; i--)
            {
                ulong t = (ulong)(n * j + i + 1);
                for (int k = 0; k < 8; k++) a[7 - k] ^= (byte)(t >> (8 * k));
                byte[] b = aes.DecryptEcb([.. a, .. r[i]], PaddingMode.None);
                a = b[..8];
                r[i] = b[8..];
            }
        return a.AsSpan().SequenceEqual(WrapCheck) ? [.. r.SelectMany(x => x)] : null;
    }
}
