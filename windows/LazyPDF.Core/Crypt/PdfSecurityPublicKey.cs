using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;

namespace LazyPDF.Core;

// The public-key handler, /Filter /Adobe.PubSec, ISO 32000-1 7.6.4 and 7.6.5: SubFilter s3 or s4 (V 1 or 2, RC4,
// /Recipients in the encryption dictionary), s5 and s4 with V 4 (crypt filters, /Recipients in the filter), and s5 with V 5.
// Each recipient is a CMS EnvelopedData holding a 20-byte seed and the recipient's 4 permission bytes;
// the file key is a digest of the seed and every EnvelopedData as stored.
public sealed partial class PdfSecurity
{
    private const int MaxRecipients = 1000;
    private const string CryptFilterName = "DefaultCryptFilter";
    private const string Aes256Cbc = "2.16.840.1.101.3.4.1.42";

    /// <summary>
    /// The handler for an /Adobe.PubSec <paramref name="encrypt"/> dictionary (fully resolved), opened
    /// with the private key of <paramref name="certificate"/>; null when the certificate is not among the
    /// recipients or has no usable private key. Throws <see cref="PdfReadException"/>: Unsupported for
    /// another SubFilter or V, a cipher that does not fit it, Damaged for no /Recipients.
    /// </summary>
    public static PdfSecurity? OpenPublicKey(PdfDictionary encrypt, X509Certificate2 certificate)
    {
        string? subFilter = (encrypt["SubFilter"] as PdfName)?.Value;
        int v = Number(encrypt, "V", 0);
        bool direct = (subFilter, v) is ("adbe.pkcs7.s3" or "adbe.pkcs7.s4", 1 or 2);
        bool known = direct || (subFilter, v) is ("adbe.pkcs7.s4", 4) or ("adbe.pkcs7.s5", 4 or 5);
        if (encrypt["Filter"] is not PdfName { Value: "Adobe.PubSec" } || !known)
            throw new PdfReadException(PdfReadProblem.Unsupported, $"The public-key handler {subFilter} with version {v} is not supported.");

        var (strings, streams, filters) = ReadFilters(encrypt, v);
        var embedded = CheckCiphers(encrypt, v, v == 5, strings, streams, filters);
        PdfDictionary? filter = null;
        if (!direct)
        {
            // Recipients sit in whichever filter the file uses; /StmF, /StrF and /EFF may each be Identity.
            var cf = encrypt["CF"] as PdfDictionary;
            filter = new[] { "StmF", "StrF", "EFF" }.Select(key => (encrypt[key] as PdfName)?.Value)
                         .Select(name => name is null ? null : cf?[name] as PdfDictionary).FirstOrDefault(f => f is not null)
                     ?? throw PdfReadException.Damaged("The public-key crypt filter is missing.");
        }
        if ((direct ? encrypt["Recipients"] : filter!["Recipients"]) is not PdfArray list)
            throw PdfReadException.Damaged("The public-key handler has no /Recipients.");
        var recipients = list.Items.Take(MaxRecipients).OfType<PdfString>().Select(s => s.Bytes).ToList();
        bool metadata = v < 4 || ((filter ?? encrypt)["EncryptMetadata"] ?? encrypt["EncryptMetadata"]) is not PdfBoolean { Value: false };
        int length = v switch { 1 => 5, 4 => 16, _ => Math.Clamp(Number(encrypt, "Length", 40) / 8, 5, 16) };

        foreach (byte[] stored in recipients)
        {
            if (Unseal(stored, certificate) is not { Length: 24 } content) continue;
            byte[] key = FileKey(v, length, content.AsSpan(0, 20), recipients, metadata);
            int p = BinaryPrimitives.ReadInt32BigEndian(content.AsSpan(20));
            return new PdfSecurity(encrypt, key, v == 5 ? 6 : v, p, (p & 2) != 0, metadata, strings, streams, filters,
                                   RandomNumberGenerator.Fill, embedded) { IsPublicKey = true };
        }
        return null;
    }

    /// <summary>
    /// A handler for a new file readable by exactly <paramref name="recipients"/>, each with their own
    /// permissions. <see cref="PdfCryptStrength.Aes256"/> makes V 5 (s5), Aes128 V 4 (also s5). The seed and
    /// the CMS content keys come from the system generator, so two calls never give the same file.
    /// The new handler is an owner: <see cref="OpenedAsOwner"/> is true and its permissions are all.
    /// </summary>
    public static PdfSecurity CreatePublicKey(IReadOnlyList<PdfRecipient> recipients, PdfCryptStrength strength)
    {
        if (recipients.Count is 0 or > MaxRecipients)
            throw new ArgumentException($"A file has between 1 and {MaxRecipients} recipients.", nameof(recipients));
        if (!recipients.All(r => PdfRecipient.CanProtect(r.Certificate)))
            throw new ArgumentException("This certificate cannot be used to protect a file. Choose a certificate with an RSA or a P-256 or P-384 key.", nameof(recipients));
        bool modern = strength == PdfCryptStrength.Aes256;
        int v = modern ? 5 : 4;
        byte[] seed = RandomNumberGenerator.GetBytes(20);

        var stored = new List<byte[]>();
        foreach (var recipient in recipients)
        {
            // Bits 7, 8 and 13 to 32 are reserved and set, as in /P.
            uint bits = 0xFFFFF0C0u | ((uint)recipient.Permissions & (uint)PdfPermissions.All) | (recipient.CanChangeEncryption ? 2u : 0);
            byte[] content = new byte[24];
            seed.CopyTo(content, 0);
            BinaryPrimitives.WriteUInt32BigEndian(content.AsSpan(20), bits);
            if (PdfCmsAgreement.CurveOf(recipient.Certificate) is not null)
            {
                stored.Add(PdfCmsAgreement.Seal(content, recipient.Certificate));
                continue;
            }
            var cms = new EnvelopedCms(new ContentInfo(content), new AlgorithmIdentifier(new Oid(Aes256Cbc)));
            cms.Encrypt(new CmsRecipient(recipient.Certificate));
            stored.Add(cms.Encode());
        }

        var filter = new PdfDictionary();
        filter.Add("Type", new PdfName("CryptFilter"));
        filter.Add("CFM", new PdfName(modern ? "AESV3" : "AESV2"));
        filter.Add("AuthEvent", new PdfName("DocOpen"));
        filter.Add("Length", new PdfNumber(modern ? 32 : 16));
        filter.Add("Recipients", new PdfArray([.. stored.Select(s => new PdfString(s, true))]));
        filter.Add("EncryptMetadata", new PdfBoolean(true));
        var cf = new PdfDictionary();
        cf.Add(CryptFilterName, filter);

        var dictionary = new PdfDictionary();
        dictionary.Add("Filter", new PdfName("Adobe.PubSec"));
        dictionary.Add("SubFilter", new PdfName("adbe.pkcs7.s5"));
        dictionary.Add("V", new PdfNumber(v));
        dictionary.Add("Length", new PdfNumber(modern ? 256 : 128));
        dictionary.Add("CF", cf);
        dictionary.Add("StmF", new PdfName(CryptFilterName));
        dictionary.Add("StrF", new PdfName(CryptFilterName));

        var method = modern ? Method.Aes256 : Method.Aes128;
        return new PdfSecurity(dictionary, FileKey(v, modern ? 32 : 16, seed, stored, true), modern ? 6 : 4, unchecked((int)(0xFFFFF0C0u | (uint)PdfPermissions.All | 2u)),
                               true, true, method, method, new() { [CryptFilterName] = method }, RandomNumberGenerator.Fill)
        { IsPublicKey = true };
    }

    // 7.6.5.3: SHA-1 of seed, recipients and, without metadata encryption, four 0xFF bytes, cut to the key length for V 1 to 4;
    // SHA-256 of the same for V 5.
    private static byte[] FileKey(int v, int length, ReadOnlySpan<byte> seed, List<byte[]> recipients, bool encryptMetadata)
    {
        using var hash = v == 5 ? IncrementalHash.CreateHash(HashAlgorithmName.SHA256) : IncrementalHash.CreateHash(HashAlgorithmName.SHA1);
        hash.AppendData(seed);
        foreach (byte[] recipient in recipients) hash.AppendData(recipient);
        if (!encryptMetadata) hash.AppendData([0xFF, 0xFF, 0xFF, 0xFF]);
        byte[] digest = hash.GetHashAndReset();
        return v == 5 ? digest : digest[..length];
    }

    private static byte[]? Unseal(byte[] stored, X509Certificate2 certificate)
    {
        if (PdfCmsAgreement.CurveOf(certificate) is not null) return PdfCmsAgreement.Unseal(stored, certificate);
        try
        {
            var cms = new EnvelopedCms();
            cms.Decode(stored);
            cms.Decrypt(new X509Certificate2Collection(certificate));
            return cms.ContentInfo.Content;
        }
        catch (CryptographicException)
        {
            return null;
        }
    }
}
