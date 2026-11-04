// Algorithm 2.B and the R 6 key wrapping are from Lazy Scan's PdfEncryption.cs.
using System.Buffers.Binary;
using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>The password and key algorithms of the standard security handler (ISO 32000-1 7.6.3, ISO 32000-2 7.6.4).</summary>
internal static class PdfKeys
{
    private static readonly byte[] Padding =
    [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ];

    // R 2 to 4

    /// <summary>The password cut or filled up to 32 bytes with the standard padding (algorithm 2, step a).</summary>
    public static byte[] Pad(ReadOnlySpan<byte> password)
    {
        byte[] padded = new byte[32];
        int length = Math.Min(password.Length, 32);
        password[..length].CopyTo(padded);
        Padding.AsSpan(0, 32 - length).CopyTo(padded.AsSpan(length));
        return padded;
    }

    /// <summary>Algorithm 2: the file key from a padded user password.</summary>
    public static byte[] FileKey(ReadOnlySpan<byte> paddedUser, ReadOnlySpan<byte> o, int p, ReadOnlySpan<byte> id,
                                 int revision, int length, bool encryptMetadata)
    {
        bool skipMetadata = revision >= 4 && !encryptMetadata;
        byte[] input = new byte[68 + id.Length + (skipMetadata ? 4 : 0)];
        paddedUser.CopyTo(input);
        o[..32].CopyTo(input.AsSpan(32));
        BinaryPrimitives.WriteInt32LittleEndian(input.AsSpan(64), p);
        id.CopyTo(input.AsSpan(68));
        if (skipMetadata) input.AsSpan(68 + id.Length).Fill(0xFF);
        byte[] hash = MD5.HashData(input);
        if (revision >= 3)
        {
            for (int i = 0; i < 50; i++) hash = MD5.HashData(hash.AsSpan(0, length));
        }
        return hash[..length];
    }

    /// <summary>Algorithms 4 and 5: the value /U holds, 32 bytes for R 2; for R 3 and later the first 16 are the check and the rest is filler.</summary>
    public static byte[] UserValue(ReadOnlySpan<byte> key, ReadOnlySpan<byte> id, int revision)
    {
        if (revision == 2) return Rc4.Apply(key, Padding);
        byte[] input = [.. Padding, .. id];
        return RoundsUp(key, Rc4.Apply(key, MD5.HashData(input)));
    }

    /// <summary>Algorithm 6: whether the key is the one /U was made from.</summary>
    public static bool CheckUser(ReadOnlySpan<byte> key, ReadOnlySpan<byte> u, ReadOnlySpan<byte> id, int revision)
    {
        int count = revision == 2 ? 32 : 16;
        return UserValue(key, id, revision).AsSpan(0, count).SequenceEqual(u[..count]);
    }

    private static byte[] OwnerKey(ReadOnlySpan<byte> owner, int revision, int length)
    {
        byte[] hash = MD5.HashData(Pad(owner));
        if (revision >= 3)
        {
            for (int i = 0; i < 50; i++) hash = MD5.HashData(hash);
        }
        return hash[..length];
    }

    /// <summary>Algorithm 7, first half: the padded user password hidden in /O, recovered with an owner password.</summary>
    public static byte[] UserPasswordFromOwner(ReadOnlySpan<byte> owner, ReadOnlySpan<byte> o, int revision, int length)
    {
        byte[] key = OwnerKey(owner, revision, length);
        return revision == 2 ? Rc4.Apply(key, o[..32]) : RoundsDown(key, o[..32].ToArray());
    }

    /// <summary>Algorithm 3: /O from the owner and user passwords.</summary>
    public static byte[] OwnerValue(ReadOnlySpan<byte> owner, ReadOnlySpan<byte> user, int revision, int length)
    {
        byte[] key = OwnerKey(owner, revision, length);
        byte[] value = Rc4.Apply(key, Pad(user));
        return revision == 2 ? value : RoundsUp(key, value);
    }

    // RC4 passes 1 to 19 with the key xored by the pass number, for encrypting.
    private static byte[] RoundsUp(ReadOnlySpan<byte> key, byte[] data)
    {
        for (int i = 1; i <= 19; i++) data = Rc4.Apply(Xored(key, i), data);
        return data;
    }

    // The same passes from 19 down to 0, for decrypting what RoundsUp made (pass 0 is the plain key).
    private static byte[] RoundsDown(ReadOnlySpan<byte> key, byte[] data)
    {
        for (int i = 19; i >= 0; i--) data = Rc4.Apply(Xored(key, i), data);
        return data;
    }

    private static byte[] Xored(ReadOnlySpan<byte> key, int value)
    {
        byte[] xored = key.ToArray();
        for (int i = 0; i < xored.Length; i++) xored[i] ^= (byte)value;
        return xored;
    }

    // R 5 and 6

    /// <summary>The hash of algorithm 2.A: SHA-256 alone for R 5, algorithm 2.B for R 6.</summary>
    public static byte[] Hash(int revision, ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt, ReadOnlySpan<byte> userKey)
    {
        if (revision == 5) return SHA256.HashData([.. password, .. salt, .. userKey]);
        return Hash2B(password, salt, userKey);
    }

    /// <summary>
    /// Algorithm 2.B of ISO 32000-2: K = SHA-256(password, salt, userKey), then rounds of
    /// E = AES-128-CBC over 64 copies of (password, K, userKey) keyed with K's first 16 bytes and
    /// IV from its next 16, and K = SHA-256, 384 or 512 of E by E's first 16 bytes summed modulo 3.
    /// At least 64 rounds, then on while E's last byte is above the round number minus 32.
    /// <paramref name="userKey"/> is the 48-byte /U for the owner password, else empty.
    /// </summary>
    private static byte[] Hash2B(ReadOnlySpan<byte> password, ReadOnlySpan<byte> salt, ReadOnlySpan<byte> userKey)
    {
        byte[] k = SHA256.HashData([.. password, .. salt, .. userKey]);
        using var aes = Aes.Create();
        byte[] e = [];
        int round = 0;
        while (round < 64 || e[^1] > round - 32)
        {
            int part = password.Length + k.Length + userKey.Length;
            byte[] k1 = new byte[part * 64];
            for (int i = 0; i < 64; i++)
            {
                var block = k1.AsSpan(i * part, part);
                password.CopyTo(block);
                k.CopyTo(block[password.Length..]);
                userKey.CopyTo(block[(password.Length + k.Length)..]);
            }
            aes.SetKey(k.AsSpan(0, 16));
            e = aes.EncryptCbc(k1, k.AsSpan(16, 16), PaddingMode.None);
            int sum = 0;
            for (int i = 0; i < 16; i++) sum += e[i];
            k = (sum % 3) switch
            {
                0 => SHA256.HashData(e),
                1 => SHA384.HashData(e),
                _ => SHA512.HashData(e),
            };
            round++;
        }
        return k[..32];
    }

    /// <summary>Algorithm 2.A: the file key when <paramref name="password"/> is the owner's (checked first) or the user's, else null.</summary>
    public static byte[]? OpenFileKey(int revision, ReadOnlySpan<byte> password, ReadOnlySpan<byte> o, ReadOnlySpan<byte> u,
                                      ReadOnlySpan<byte> oe, ReadOnlySpan<byte> ue, out bool asOwner)
    {
        var userBytes = u[..48];
        asOwner = true;
        if (Hash(revision, password, o[32..40], userBytes).AsSpan().SequenceEqual(o[..32]))
        {
            return UnwrapKey(Hash(revision, password, o[40..48], userBytes), oe);
        }
        asOwner = false;
        if (Hash(revision, password, u[32..40], []).AsSpan().SequenceEqual(u[..32]))
        {
            return UnwrapKey(Hash(revision, password, u[40..48], []), ue);
        }
        return null;
    }

    private static byte[] UnwrapKey(byte[] key, ReadOnlySpan<byte> wrapped)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        return aes.DecryptCbc(wrapped[..32], stackalloc byte[16], PaddingMode.None);
    }

    /// <summary>/UE and /OE: the file key under a key made from a password, zero IV and no padding.</summary>
    public static byte[] WrapKey(byte[] key, ReadOnlySpan<byte> fileKey)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        return aes.EncryptCbc(fileKey, stackalloc byte[16], PaddingMode.None);
    }

    /// <summary>Algorithm 2.A step on /Perms: decrypts it and compares /P, the metadata flag and the "adb" marker.</summary>
    public static bool PermsMatch(byte[] fileKey, ReadOnlySpan<byte> perms, int p, bool encryptMetadata)
    {
        if (perms.Length < 16) return false;
        Span<byte> block = stackalloc byte[16];
        using var aes = Aes.Create();
        aes.Key = fileKey;
        aes.DecryptEcb(perms[..16], block, PaddingMode.None);
        return BinaryPrimitives.ReadInt32LittleEndian(block) == p
               && block[8] == (encryptMetadata ? (byte)'T' : (byte)'F')
               && block[9..12].SequenceEqual("adb"u8);
    }

    /// <summary>Algorithm 10: /Perms, the permissions and the metadata flag under the file key, so a changed /P is noticed.</summary>
    public static byte[] Perms(byte[] fileKey, int p, ReadOnlySpan<byte> filler)
    {
        Span<byte> block = stackalloc byte[16];
        BinaryPrimitives.WriteInt32LittleEndian(block, p);
        block[4..8].Fill(0xFF);
        block[8] = (byte)'T';
        block[9] = (byte)'a';
        block[10] = (byte)'d';
        block[11] = (byte)'b';
        filler[..4].CopyTo(block[12..]);
        using var aes = Aes.Create();
        aes.Key = fileKey;
        return aes.EncryptEcb(block, PaddingMode.None);
    }
}
