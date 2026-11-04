using System.Security.Cryptography;
using System.Text;

namespace LazyPDF.Core.Tests;

internal sealed record BuiltEncryption(PdfDictionary Dictionary, byte[] FileKey);

/// <summary>
/// /Encrypt dictionaries made straight from the algorithms of ISO 32000-1 7.6.3 and ISO 32000-2
/// 7.6.4 with fixed inputs, to check the reader against a second reading of the spec. R 6 borrows
/// the library's hash; the pypdf fixtures vouch for it.
/// </summary>
internal static class SyntheticEncryption
{
    public static readonly byte[] Id = Convert.FromHexString("0123456789ABCDEF0123456789ABCDEF");

    private static readonly byte[] Padding = Convert.FromHexString("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A");

    public static BuiltEncryption Legacy(int v, int r, int bits, string user, string owner, int p = -4,
                                         bool encryptMetadata = true, string? cfm = null, string strF = "StdCF", string stmF = "StdCF")
    {
        int n = r == 2 ? 5 : r == 4 ? 16 : bits / 8;
        byte[] userPad = Pad(user);

        byte[] ownerHash = MD5.HashData(Pad(owner));
        if (r >= 3) for (int i = 0; i < 50; i++) ownerHash = MD5.HashData(ownerHash);
        byte[] ownerKey = ownerHash[..n];
        byte[] o = Rc4.Apply(ownerKey, userPad);
        if (r >= 3) for (int i = 1; i <= 19; i++) o = Rc4.Apply(Xor(ownerKey, i), o);

        byte[] input = [.. userPad, .. o, .. BitConverter.GetBytes(p), .. Id];
        if (r >= 4 && !encryptMetadata) input = [.. input, 0xFF, 0xFF, 0xFF, 0xFF];
        byte[] hash = MD5.HashData(input);
        if (r >= 3) for (int i = 0; i < 50; i++) hash = MD5.HashData(hash[..n]);
        byte[] key = hash[..n];

        byte[] u;
        if (r == 2)
        {
            u = Rc4.Apply(key, Padding);
        }
        else
        {
            u = Rc4.Apply(key, MD5.HashData([.. Padding, .. Id]));
            for (int i = 1; i <= 19; i++) u = Rc4.Apply(Xor(key, i), u);
            u = [.. u, .. new byte[16]];
        }

        var dictionary = new PdfDictionary();
        dictionary.Add("Filter", new PdfName("Standard"));
        dictionary.Add("V", new PdfNumber(v));
        dictionary.Add("R", new PdfNumber(r));
        if (v >= 2) dictionary.Add("Length", new PdfNumber(bits));
        dictionary.Add("P", new PdfNumber(p));
        dictionary.Add("O", new PdfString(o, true));
        dictionary.Add("U", new PdfString(u, true));
        if (v == 4)
        {
            var std = new PdfDictionary();
            std.Add("CFM", new PdfName(cfm!));
            var rc4 = new PdfDictionary();
            rc4.Add("CFM", new PdfName("V2"));
            var cf = new PdfDictionary();
            cf.Add("StdCF", std);
            cf.Add("Rc4CF", rc4);
            dictionary.Add("CF", cf);
            dictionary.Add("StmF", new PdfName(stmF));
            dictionary.Add("StrF", new PdfName(strF));
            if (!encryptMetadata) dictionary.Add("EncryptMetadata", new PdfBoolean(false));
        }
        return new(dictionary, key);
    }

    public static BuiltEncryption Modern(int r, string user, string owner, int p = -4)
    {
        byte[] fileKey = Enumerable.Range(1, 32).Select(i => (byte)(i * 7)).ToArray();
        byte[] userPw = Encoding.UTF8.GetBytes(user), ownerPw = Encoding.UTF8.GetBytes(owner);
        byte[] uValidation = "uvalid01"u8.ToArray(), uKeySalt = "ukeysalt"u8.ToArray();
        byte[] oValidation = "ovalid01"u8.ToArray(), oKeySalt = "okeysalt"u8.ToArray();

        byte[] u = [.. Hash(r, userPw, uValidation, []), .. uValidation, .. uKeySalt];
        byte[] ue = Wrap(Hash(r, userPw, uKeySalt, []), fileKey);
        byte[] o = [.. Hash(r, ownerPw, oValidation, u), .. oValidation, .. oKeySalt];
        byte[] oe = Wrap(Hash(r, ownerPw, oKeySalt, u), fileKey);

        var std = new PdfDictionary();
        std.Add("CFM", new PdfName("AESV3"));
        var cf = new PdfDictionary();
        cf.Add("StdCF", std);
        var dictionary = new PdfDictionary();
        dictionary.Add("Filter", new PdfName("Standard"));
        dictionary.Add("V", new PdfNumber(5));
        dictionary.Add("R", new PdfNumber(r));
        dictionary.Add("Length", new PdfNumber(256));
        dictionary.Add("P", new PdfNumber(p));
        dictionary.Add("CF", cf);
        dictionary.Add("StmF", new PdfName("StdCF"));
        dictionary.Add("StrF", new PdfName("StdCF"));
        dictionary.Add("O", new PdfString(o, true));
        dictionary.Add("U", new PdfString(u, true));
        dictionary.Add("OE", new PdfString(oe, true));
        dictionary.Add("UE", new PdfString(ue, true));
        return new(dictionary, fileKey);
    }

    /// <summary>What a writer stores for an RC4 object (algorithm 1).</summary>
    public static byte[] StoreRc4(byte[] fileKey, int number, int generation, byte[] plain) =>
        Rc4.Apply(ObjectKey(fileKey, number, generation, false), plain);

    /// <summary>What a writer stores for an AES-128 object: the IV, then the PKCS#7 padded cipher text.</summary>
    public static byte[] StoreAes128(byte[] fileKey, int number, int generation, byte[] plain) =>
        StoreAes(ObjectKey(fileKey, number, generation, true), plain);

    public static byte[] StoreAes256(byte[] fileKey, byte[] plain) => StoreAes(fileKey, plain);

    private static byte[] StoreAes(byte[] key, byte[] plain)
    {
        byte[] iv = Enumerable.Range(0, 16).Select(i => (byte)(200 - i)).ToArray();
        using var aes = Aes.Create();
        aes.Key = key;
        return [.. iv, .. aes.EncryptCbc(plain, iv, PaddingMode.PKCS7)];
    }

    private static byte[] ObjectKey(byte[] fileKey, int number, int generation, bool aes)
    {
        byte[] input = [.. fileKey, (byte)number, (byte)(number >> 8), (byte)(number >> 16), (byte)generation, (byte)(generation >> 8)];
        if (aes) input = [.. input, .. "sAlT"u8.ToArray()];
        return MD5.HashData(input)[..Math.Min(fileKey.Length + 5, 16)];
    }

    private static byte[] Hash(int r, byte[] password, byte[] salt, byte[] userKey) =>
        r == 5 ? SHA256.HashData([.. password, .. salt, .. userKey]) : PdfKeys.Hash(6, password, salt, userKey);

    private static byte[] Wrap(byte[] key, byte[] fileKey)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        return aes.EncryptCbc(fileKey, new byte[16], PaddingMode.None);
    }

    private static byte[] Pad(string password)
    {
        byte[] bytes = Encoding.Latin1.GetBytes(password);
        return new[] { bytes, Padding }.SelectMany(b => b).Take(32).ToArray();
    }

    private static byte[] Xor(byte[] key, int value) => key.Select(b => (byte)(b ^ value)).ToArray();
}
