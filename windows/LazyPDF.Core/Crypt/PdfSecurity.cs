using System.Security.Cryptography;

namespace LazyPDF.Core;

/// <summary>
/// The standard security handler (ISO 32000-1 7.6, ISO 32000-2 7.6 for R 6): opens an /Encrypt
/// dictionary with a password, decrypts and encrypts strings and streams, and makes the dictionary
/// of a new file. Read: V 1 R 2 and V 2 R 3 (RC4), V 4 R 4 (crypt filters: RC4, AES-128, identity),
/// V 5 R 5 and R 6 (AES-256). Written: R 4 and R 6. An instance holds the file key and no state
/// that changes, so it can be shared between threads.
/// </summary>
public sealed partial class PdfSecurity
{
    private enum Method { Identity, Rc4, Aes128, Aes256 }

    private readonly byte[] _key;
    private readonly Method _strings;
    private readonly Method _streams;
    private readonly Method _embedded;
    private readonly Dictionary<string, Method> _filters;
    private readonly int _permissionBits;
    private readonly Action<Span<byte>> _fill;

    private PdfSecurity(PdfDictionary dictionary, byte[] key, int revision, int permissionBits, bool openedAsOwner,
                        bool encryptMetadata, Method strings, Method streams, Dictionary<string, Method> filters,
                        Action<Span<byte>> fill, Method? embedded = null)
    {
        Dictionary = dictionary;
        _key = key;
        Revision = revision;
        _permissionBits = permissionBits;
        OpenedAsOwner = openedAsOwner;
        EncryptMetadata = encryptMetadata;
        _strings = strings;
        _streams = streams;
        _embedded = embedded ?? streams;
        _filters = filters;
        _fill = fill;
    }

    /// <summary>Whether the password was the owner's, so the permissions do not bind this reader.</summary>
    public bool OpenedAsOwner { get; }

    /// <summary>What the file's /P allows. For a reader that opened as owner these are still the file's flags.</summary>
    public PdfPermissions Permissions => (PdfPermissions)(_permissionBits & (int)PdfPermissions.All);

    /// <summary>False when the document's metadata stream is stored in the clear (R 4 and later).</summary>
    public bool EncryptMetadata { get; }

    /// <summary>
    /// An R 6 file whose /Perms is missing or does not agree with /P and /EncryptMetadata under the
    /// file key: someone changed the permissions without the key. The file still opens; false for
    /// every other revision and for a new handler.
    /// </summary>
    public bool PermsMismatch { get; private init; }

    /// <summary>Whether this is the public-key handler (<see cref="OpenPublicKey"/>, <see cref="CreatePublicKey"/>).</summary>
    public bool IsPublicKey { get; private init; }

    /// <summary>The revision; for the public-key handler 4 for V 4 and 6 for V 5, so the version rules of a save treat both handlers alike.</summary>
    public int Revision { get; }

    /// <summary>The /Encrypt dictionary: the one given to <see cref="Open"/>, or the new one. It is never encrypted itself.</summary>
    public PdfDictionary Dictionary { get; }

    /// <summary>
    /// The handler for <paramref name="encrypt"/> (fully resolved) and the first string of the
    /// trailer's /ID, or null when <paramref name="password"/> is neither the user's nor the
    /// owner's. A null or empty password tries the empty user password. Throws
    /// <see cref="PdfReadException"/> for a handler or cipher that is not supported, or values
    /// missing from the dictionary.
    /// </summary>
    public static PdfSecurity? Open(PdfDictionary encrypt, byte[] firstId, string? password)
    {
        if (encrypt["Filter"] is not PdfName { Value: "Standard" })
            throw new PdfReadException(PdfReadProblem.Unsupported, "The file uses a security handler other than the standard one.");
        int v = Number(encrypt, "V", 0), r = Number(encrypt, "R", 0);
        if (!((v is 1 or 2 or 4 && r is >= 2 and <= 4) || (v == 5 && r is 5 or 6)))
            throw new PdfReadException(PdfReadProblem.Unsupported, $"The encryption version {v} revision {r} is not supported.");

        var (strings, streams, filters) = ReadFilters(encrypt, v);
        bool modern = r >= 5;
        var embedded = CheckCiphers(encrypt, v, modern, strings, streams, filters);

        byte[] o = Bytes(encrypt, "O"), u = Bytes(encrypt, "U");
        int p = unchecked((int)(long)(encrypt["P"] is PdfNumber number ? number.Value : 0));
        bool metadata = r < 4 || encrypt["EncryptMetadata"] is not PdfBoolean { Value: false };
        password ??= "";

        byte[]? key;
        bool owner;
        if (modern)
        {
            byte[] oe = Bytes(encrypt, "OE"), ue = Bytes(encrypt, "UE");
            if (o.Length < 48 || u.Length < 48 || oe.Length < 32 || ue.Length < 32)
                throw PdfReadException.Damaged("The encryption dictionary has short password values.");
            key = OpenModern(r, password, o, u, oe, ue, out owner);
        }
        else
        {
            if (o.Length < 32 || u.Length < 32)
                throw PdfReadException.Damaged("The encryption dictionary has short password values.");
            int length = r == 2 ? 5 : r == 4 ? 16 : Math.Clamp(Number(encrypt, "Length", 40) / 8, 5, 16);
            if (length != 16 && filters.Values.Append(strings).Append(streams).Append(embedded).Contains(Method.Aes128))
                throw new PdfReadException(PdfReadProblem.Unsupported, "AES-128 needs a 128-bit key.");
            key = OpenLegacy(PdfPasswords.Legacy(password), o, u, p, firstId, r, length, metadata, out owner);
        }
        if (key is null) return null;
        // R 6 only: the /Perms of R 5 files in the wild are not reliable.
        bool mismatch = r == 6 && !(encrypt["Perms"] is PdfString perms && PdfKeys.PermsMatch(key, perms.Bytes, p, metadata));
        return new PdfSecurity(encrypt, key, r, p, owner, metadata, strings, streams, filters,
                               RandomNumberGenerator.Fill, embedded) { PermsMismatch = mismatch };
    }

    /// <summary>The method of embedded files, after checking that every cipher in use belongs to the revision.</summary>
    private static Method CheckCiphers(PdfDictionary encrypt, int v, bool modern, Method strings, Method streams,
                                       Dictionary<string, Method> filters)
    {
        var embedded = v >= 4 && encrypt["EFF"] is PdfName eff ? Named(eff, filters) : streams;
        foreach (var method in filters.Values.Append(strings).Append(streams).Append(embedded))
        {
            if (method != Method.Identity && (method == Method.Aes256) != modern)
                throw new PdfReadException(PdfReadProblem.Unsupported, "The crypt filter does not match the encryption revision.");
        }
        return embedded;
    }

    private static byte[]? OpenLegacy(byte[] password, byte[] o, byte[] u, int p, byte[] id, int r, int length,
                                      bool metadata, out bool owner)
    {
        owner = true;
        byte[] hidden = PdfKeys.UserPasswordFromOwner(password, o, r, length);
        byte[] key = PdfKeys.FileKey(hidden, o, p, id, r, length, metadata);
        if (PdfKeys.CheckUser(key, u, id, r)) return key;
        owner = false;
        key = PdfKeys.FileKey(PdfKeys.Pad(password), o, p, id, r, length, metadata);
        return PdfKeys.CheckUser(key, u, id, r) ? key : null;
    }

    private static byte[]? OpenModern(int r, string password, byte[] o, byte[] u, byte[] oe, byte[] ue, out bool owner)
    {
        // PDFKit hands on the decomposed form, so files made on a Mac can need it.
        byte[] prepared = PdfPasswords.Prepare(password), decomposed = PdfPasswords.Decompose(password);
        byte[]? key = PdfKeys.OpenFileKey(r, prepared, o, u, oe, ue, out owner);
        if (key is null && !decomposed.AsSpan().SequenceEqual(prepared))
        {
            key = PdfKeys.OpenFileKey(r, decomposed, o, u, oe, ue, out owner);
        }
        return key;
    }

    private static (Method Strings, Method Streams, Dictionary<string, Method> Filters) ReadFilters(PdfDictionary encrypt, int v)
    {
        var filters = new Dictionary<string, Method>();
        if (v < 4) return (Method.Rc4, Method.Rc4, filters);
        if (encrypt["CF"] is PdfDictionary cf)
        {
            foreach (var (name, value) in cf.Entries)
            {
                if (value is PdfDictionary filter) filters[name] = MethodOf(filter["CFM"]);
            }
        }
        return (Named(encrypt["StrF"], filters), Named(encrypt["StmF"], filters), filters);
    }

    private static Method MethodOf(PdfObject? cfm) => (cfm as PdfName)?.Value switch
    {
        null or "None" => Method.Identity,
        "V2" => Method.Rc4,
        "AESV2" => Method.Aes128,
        "AESV3" => Method.Aes256,
        var other => throw new PdfReadException(PdfReadProblem.Unsupported, $"The crypt filter method {other} is not supported."),
    };

    private static Method Named(PdfObject? name, Dictionary<string, Method> filters)
    {
        if (name is not PdfName { Value: not "Identity" } named) return Method.Identity;
        return filters.TryGetValue(named.Value, out var method)
            ? method
            : throw PdfReadException.Damaged($"The crypt filter {named.Value} is not defined.");
    }

    private static int Number(PdfDictionary dictionary, string key, int fallback) =>
        dictionary[key] is PdfNumber { Integer: { } n } ? (int)Math.Clamp(n, int.MinValue, int.MaxValue) : fallback;

    private static byte[] Bytes(PdfDictionary dictionary, string key) =>
        dictionary[key] is PdfString text ? text.Bytes : throw PdfReadException.Damaged($"The encryption dictionary has no /{key} string.");

    /// <summary>A string of object <paramref name="number"/> as stored, decrypted. Identity returns <paramref name="data"/> itself.</summary>
    public byte[] DecryptString(int number, int generation, byte[] data) => Decrypt(_strings, number, generation, data);

    /// <summary>
    /// A stream of object <paramref name="number"/> as stored, decrypted. A cross-reference stream
    /// is never encrypted, nor is a metadata stream when <see cref="EncryptMetadata"/> is false,
    /// and a /Crypt filter naming Identity (or no filter name) leaves its stream alone. The
    /// dictionary's /Filter and /DecodeParms must be resolved.
    /// </summary>
    public byte[] DecryptStream(int number, int generation, byte[] data, PdfDictionary streamDictionary) =>
        Decrypt(StreamMethod(streamDictionary), number, generation, data);

    /// <summary>The stored form of a string, with the key <see cref="DecryptString"/> reads it with. AES gets a fresh random IV.</summary>
    public byte[] EncryptString(int number, int generation, byte[] data) => Encrypt(_strings, number, generation, data);

    /// <summary>The stored form of a stream, under the same rules as <see cref="DecryptStream"/>.</summary>
    public byte[] EncryptStream(int number, int generation, byte[] data, PdfDictionary streamDictionary) =>
        Encrypt(StreamMethod(streamDictionary), number, generation, data);

    private Method StreamMethod(PdfDictionary stream)
    {
        if (stream["Type"] is PdfName type && (type.Value == "XRef" || type.Value == "Metadata" && !EncryptMetadata))
            return Method.Identity;
        int index = CryptFilterIndex(stream["Filter"]);
        if (index < 0) return stream["Type"] is PdfName { Value: "EmbeddedFile" } ? _embedded : _streams;
        var parms = stream["DecodeParms"] ?? stream["DP"];
        if (parms is PdfArray array) parms = index < array.Items.Count ? array.Items[index] : null;
        string name = parms is PdfDictionary d && d["Name"] is PdfName n ? n.Value : "Identity";
        if (name == "Identity") return Method.Identity;
        return _filters.GetValueOrDefault(name, _streams);
    }

    private static int CryptFilterIndex(PdfObject? filter) => filter switch
    {
        PdfName { Value: "Crypt" } => 0,
        PdfArray array => array.Items.FindIndex(f => f is PdfName { Value: "Crypt" }),
        _ => -1,
    };

    private byte[] Decrypt(Method method, int number, int generation, byte[] data) => method switch
    {
        Method.Identity => data,
        Method.Rc4 => Rc4.Apply(ObjectKey(number, generation, false), data),
        Method.Aes128 => AesDecrypt(ObjectKey(number, generation, true), data),
        _ => AesDecrypt(_key, data),
    };

    private byte[] Encrypt(Method method, int number, int generation, byte[] data) => method switch
    {
        Method.Identity => data,
        Method.Rc4 => Rc4.Apply(ObjectKey(number, generation, false), data),
        Method.Aes128 => AesEncrypt(ObjectKey(number, generation, true), data),
        _ => AesEncrypt(_key, data),
    };

    /// <summary>Algorithm 1: the file key extended with the object and generation numbers, hashed (ISO 32000-1 7.6.2).</summary>
    private byte[] ObjectKey(int number, int generation, bool aes)
    {
        int length = _key.Length;
        Span<byte> input = stackalloc byte[length + 9];
        _key.CopyTo(input);
        input[length] = (byte)number;
        input[length + 1] = (byte)(number >> 8);
        input[length + 2] = (byte)(number >> 16);
        input[length + 3] = (byte)generation;
        input[length + 4] = (byte)(generation >> 8);
        if (aes) "sAlT"u8.CopyTo(input[(length + 5)..]);
        Span<byte> hash = stackalloc byte[16];
        MD5.HashData(input[..(length + (aes ? 9 : 5))], hash);
        return hash[..Math.Min(length + 5, 16)].ToArray();
    }

    // The IV is the first 16 bytes. A bad padding tail is kept rather than rejected, as the files in
    // the wild have them; a trailing partial block is dropped.
    private static byte[] AesDecrypt(ReadOnlySpan<byte> key, byte[] data)
    {
        int body = (data.Length - 16) & ~15;
        if (body <= 0) return [];
        using var aes = Aes.Create();
        aes.SetKey(key);
        var iv = data.AsSpan(0, 16);
        try
        {
            return aes.DecryptCbc(data.AsSpan(16, body), iv, PaddingMode.PKCS7);
        }
        catch (CryptographicException)
        {
            return aes.DecryptCbc(data.AsSpan(16, body), iv, PaddingMode.None);
        }
    }

    private byte[] AesEncrypt(ReadOnlySpan<byte> key, byte[] data)
    {
        using var aes = Aes.Create();
        aes.SetKey(key);
        byte[] stored = new byte[16 + aes.GetCiphertextLengthCbc(data.Length, PaddingMode.PKCS7)];
        _fill(stored.AsSpan(0, 16));
        aes.EncryptCbc(data, stored.AsSpan(0, 16), stored.AsSpan(16), PaddingMode.PKCS7);
        return stored;
    }
}
