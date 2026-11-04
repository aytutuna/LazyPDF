using System.Security.Cryptography;

namespace LazyPDF.Core;

public sealed partial class PdfSecurity
{
    /// <summary>
    /// A handler for a new file. An empty <paramref name="ownerPassword"/> becomes random bytes
    /// nobody knows, so the permissions bind everyone who opens the file. The keys, salts and IVs
    /// come from <paramref name="random"/> (null: the system's cryptographic generator); a seeded
    /// one is for tests. <paramref name="firstId"/> is the first string of the trailer's /ID, which
    /// <see cref="PdfCryptStrength.Aes128"/> mixes into the key.
    /// </summary>
    public static PdfSecurity Create(string userPassword, string ownerPassword, PdfPermissions permissions,
                                     PdfCryptStrength strength, byte[] firstId, Random? random = null)
    {
        Action<Span<byte>> fill = random is null ? RandomNumberGenerator.Fill : random.NextBytes;
        // Bits 7, 8 and 13 to 32 are reserved and must be set (ISO 32000-1 7.6.3.2).
        int p = unchecked((int)(0xFFFFF0C0u | ((uint)permissions & (uint)PdfPermissions.All)));
        return strength == PdfCryptStrength.Aes128
            ? CreateAes128(userPassword, ownerPassword, p, firstId, fill)
            : CreateAes256(userPassword, ownerPassword, p, fill);
    }

    private static byte[] RandomBytes(Action<Span<byte>> fill, int length)
    {
        byte[] bytes = new byte[length];
        fill(bytes);
        return bytes;
    }

    private static PdfSecurity CreateAes256(string userPassword, string ownerPassword, int p, Action<Span<byte>> fill)
    {
        byte[] user = PdfPasswords.Prepare(userPassword), owner = PdfPasswords.Prepare(ownerPassword);
        byte[] fileKey = RandomBytes(fill, 32);
        byte[] userValidation = RandomBytes(fill, 8), userKeySalt = RandomBytes(fill, 8);
        byte[] ownerValidation = RandomBytes(fill, 8), ownerKeySalt = RandomBytes(fill, 8);
        if (owner.Length == 0) owner = RandomBytes(fill, 32);

        byte[] u = [.. PdfKeys.Hash(6, user, userValidation, []), .. userValidation, .. userKeySalt];
        byte[] ue = PdfKeys.WrapKey(PdfKeys.Hash(6, user, userKeySalt, []), fileKey);
        // The owner values are hashed together with the whole of /U.
        byte[] o = [.. PdfKeys.Hash(6, owner, ownerValidation, u), .. ownerValidation, .. ownerKeySalt];
        byte[] oe = PdfKeys.WrapKey(PdfKeys.Hash(6, owner, ownerKeySalt, u), fileKey);
        byte[] perms = PdfKeys.Perms(fileKey, p, RandomBytes(fill, 4));

        var dictionary = Standard(5, 6, 256, p, o, u, "AESV3", 32);
        dictionary.Add("OE", new PdfString(oe, true));
        dictionary.Add("UE", new PdfString(ue, true));
        dictionary.Add("Perms", new PdfString(perms, true));
        dictionary.Add("EncryptMetadata", new PdfBoolean(true));
        return new PdfSecurity(dictionary, fileKey, 6, p, true, true, Method.Aes256, Method.Aes256,
                               new() { ["StdCF"] = Method.Aes256 }, fill);
    }

    private static PdfSecurity CreateAes128(string userPassword, string ownerPassword, int p, byte[] id, Action<Span<byte>> fill)
    {
        byte[] user = PdfPasswords.Legacy(userPassword), owner = PdfPasswords.Legacy(ownerPassword);
        if (owner.Length == 0) owner = RandomBytes(fill, 16);

        byte[] o = PdfKeys.OwnerValue(owner, user, 4, 16);
        byte[] key = PdfKeys.FileKey(PdfKeys.Pad(user), o, p, id, 4, 16, true);
        // Only the first 16 bytes of /U are checked; the readers fill the rest with anything.
        byte[] u = [.. PdfKeys.UserValue(key, id, 4), .. new byte[16]];

        var dictionary = Standard(4, 4, 128, p, o, u, "AESV2", 16);
        return new PdfSecurity(dictionary, key, 4, p, true, true, Method.Aes128, Method.Aes128,
                               new() { ["StdCF"] = Method.Aes128 }, fill);
    }

    private static PdfDictionary Standard(int v, int r, int bits, int p, byte[] o, byte[] u, string method, int keyBytes)
    {
        var filter = new PdfDictionary();
        filter.Add("CFM", new PdfName(method));
        filter.Add("AuthEvent", new PdfName("DocOpen"));
        filter.Add("Length", new PdfNumber(keyBytes));
        var cf = new PdfDictionary();
        cf.Add("StdCF", filter);

        var dictionary = new PdfDictionary();
        dictionary.Add("Filter", new PdfName("Standard"));
        dictionary.Add("V", new PdfNumber(v));
        dictionary.Add("R", new PdfNumber(r));
        dictionary.Add("Length", new PdfNumber(bits));
        dictionary.Add("CF", cf);
        dictionary.Add("StmF", new PdfName("StdCF"));
        dictionary.Add("StrF", new PdfName("StdCF"));
        dictionary.Add("O", new PdfString(o, true));
        dictionary.Add("U", new PdfString(u, true));
        dictionary.Add("P", new PdfNumber(p));
        return dictionary;
    }
}
