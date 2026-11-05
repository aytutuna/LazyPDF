using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography.Xml;
using System.Text;

namespace LazyPDF.Core.Tests;

// Mirrored by Tests/LazyPDFKitTests/Crypt/CryptGolden.swift. One line of input is "<op> <words>"; the result is
// what the key algorithms, the password preparation and the two handlers made of them, in text. Passwords are
// escaped UTF-8 bytes ("-" is the empty password), byte values are hex ("-" is none). The public-key files are
// made here by WriteSealedFiles, each only when it is not there yet, and read by both sides as fixed inputs.
internal static class CryptGolden
{
    public static readonly byte[] Secret = "Sealed by the Windows engine"u8.ToArray();

    private static string SourceFolder([CallerFilePath] string path = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, "..", "..", "..", "Tests", "Fixtures", "golden", "crypt"));

    private static string Folder => Environment.GetEnvironmentVariable("LAZYPDF_WRITE_GOLDEN") == "1"
                                    || Environment.GetEnvironmentVariable("LAZYPDF_WRITE_FIXTURES") == "1"
        ? SourceFolder()
        : Path.Combine(AppContext.BaseDirectory, "Fixtures", "golden", "crypt");

    private static byte[] File(string name) => System.IO.File.ReadAllBytes(Path.Combine(Folder, name));

    public static string Run(string input)
    {
        var output = new StringBuilder();
        foreach (string line in input.Split('\n'))
        {
            if (line.Length == 0 || line.StartsWith("# ", StringComparison.Ordinal)) continue;
            string[] words = line.Split(' ');
            output.Append("> ").Append(line).Append('\n').Append("< ").Append(Op(words[0], words[1..])).Append('\n');
        }
        return output.ToString();
    }

    private static string Op(string op, string[] words)
    {
        try
        {
            switch (op)
            {
                case "password":
                    string text = Text(words.ElementAtOrDefault(0));
                    return $"prepare={Hex(PdfPasswords.Prepare(text))} decompose={Hex(PdfPasswords.Decompose(text))} legacy={Hex(PdfPasswords.Legacy(text))}";
                case "hash":
                    return Hex(PdfKeys.Hash(int.Parse(words[0]), Bytes(Text(words[1])), Convert.FromHexString(words[2]), Optional(words[3])));
                case "legacy":
                    return Legacy(int.Parse(words[0]), int.Parse(words[1]), words[2] == "1", Text(words[3]), Text(words[4]), Optional(words[5]));
                case "perms":
                    byte[] fileKey = Convert.FromHexString(words[0]);
                    int p = int.Parse(words[1]);
                    byte[] perms = PdfKeys.Perms(fileKey, p, Convert.FromHexString(words[2]));
                    return $"{Hex(perms)} match={Bool(PdfKeys.PermsMatch(fileKey, perms, p, true))}";
                case "fixture":
                    return Fixture(words[0], Text(words[1]));
                case "certificate":
                    return Describe(Certificate(words[0]));
                case "recipients":
                    return Recipients(words[0]);
                case "publickey":
                    return PublicKey(words[0], words[1]);
                default:
                    throw new InvalidOperationException($"No op \"{op}\".");
            }
        }
        catch (PdfReadException e)
        {
            string problem = e.Problem.ToString();
            return $"error {char.ToLowerInvariant(problem[0])}{problem[1..]}: {Golden.Escape(e.Message)}";
        }
    }

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes);

    private static string Bool(bool value) => value ? "true" : "false";

    private static string Text(string? word) =>
        word is null or "-" ? "" : Encoding.UTF8.GetString(Golden.Unescape(word));

    private static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);

    private static byte[] Optional(string word) => word == "-" ? [] : Convert.FromHexString(word);

    private static string Legacy(int r, int length, bool metadata, string user, string owner, byte[] id)
    {
        byte[] userBytes = PdfPasswords.Legacy(user), ownerBytes = PdfPasswords.Legacy(owner);
        byte[] o = PdfKeys.OwnerValue(ownerBytes, userBytes, r, length);
        byte[] key = PdfKeys.FileKey(PdfKeys.Pad(userBytes), o, -4, id, r, length, metadata);
        byte[] u = PdfKeys.UserValue(key, id, r);
        byte[] hidden = PdfKeys.UserPasswordFromOwner(ownerBytes, o, r, length);
        return $"o={Hex(o)} key={Hex(key)} u={Hex(u)} hidden={Hex(hidden)} check={Bool(PdfKeys.CheckUser(key, u, id, r))}";
    }

    private static string Fixture(string name, string password)
    {
        var file = EncryptedFixture.Load(name);
        var security = PdfSecurity.Open(file.Encrypt, file.Id, password);
        if (security is null) return "none";
        byte[] plain = security.DecryptStream(4, 0, file.Content, file.ContentDictionary);
        return $"owner={Bool(security.OpenedAsOwner)} revision={security.Revision} permissions={(int)security.Permissions} " +
               $"metadata={Bool(security.EncryptMetadata)} perms-mismatch={Bool(security.PermsMismatch)} content={Hex(plain)}";
    }

    // The two lines of a sealed file: the /Encrypt dictionary in PDF syntax, and the hex of Secret as object 4's string.
    private static (PdfDictionary Dictionary, byte[] Cipher) Sealed(string name)
    {
        string[] lines = Encoding.ASCII.GetString(File(name)).Split('\n');
        var dictionary = (PdfDictionary)new PdfLexer(new PdfArrayBytes(Encoding.ASCII.GetBytes(lines[0]))).ReadObject();
        return (dictionary, Convert.FromHexString(lines[1]));
    }

    private static X509Certificate2 Certificate(string name, bool withKey = true)
    {
        var certificate = X509CertificateLoader.LoadCertificate(File($"{name}-cert.der"));
        if (!withKey) return certificate;
        using var rsa = RSA.Create();
        rsa.ImportRSAPrivateKey(File($"{name}-key.der"), out _);
        return certificate.CopyWithPrivateKey(rsa);
    }

    private static string Describe(X509Certificate2 certificate)
    {
        var identifier = certificate.Extensions.OfType<X509SubjectKeyIdentifierExtension>().Single();
        return $"issuer={Hex(certificate.IssuerName.RawData)} serial={Trimmed(certificate.SerialNumberBytes.ToArray())} " +
               $"key-id={Hex(Convert.FromHexString(identifier.SubjectKeyIdentifier!))}";
    }

    private static string Trimmed(byte[] serial) => Hex(serial).TrimStart('0');

    private static string Recipients(string name)
    {
        var (dictionary, _) = Sealed(name);
        var cf = (PdfDictionary)dictionary["CF"]!;
        var filter = (PdfDictionary)cf[((PdfName)dictionary["StmF"]!).Value]!;
        var entries = ((PdfArray)filter["Recipients"]!).Items.Select(i => ((PdfString)i).Bytes).ToList();
        var parts = new List<string> { $"entries={entries.Count}" };
        foreach (byte[] entry in entries)
        {
            var cms = new EnvelopedCms();
            cms.Decode(entry);
            var info = cms.RecipientInfos[0];
            string who = info.RecipientIdentifier.Value is X509IssuerSerial issuer
                ? $"serial={issuer.SerialNumber.TrimStart('0')}"
                : $"key-id={info.RecipientIdentifier.Value}";
            parts.Add($"key={info.KeyEncryptionAlgorithm.Oid.Value} content={cms.ContentEncryptionAlgorithm.Oid.Value} {who}");
        }
        return string.Join(" | ", parts);
    }

    private static string PublicKey(string name, string holder)
    {
        var (dictionary, cipher) = Sealed(name);
        var security = PdfSecurity.OpenPublicKey(dictionary, Certificate(holder));
        if (security is null) return "none";
        byte[] plain = security.DecryptString(4, 0, cipher);
        return $"owner={Bool(security.OpenedAsOwner)} revision={security.Revision} permissions={(int)security.Permissions} " +
               $"public-key={Bool(security.IsPublicKey)} text={Golden.Escape(plain)}";
    }

    /// <summary>
    /// The certificates and the sealed files the public-key cases read, each written only when it is not there
    /// yet: they are fixed inputs, so a golden write never changes them. Delete one to make it again.
    /// </summary>
    public static void WriteSealedFiles()
    {
        string folder = SourceFolder();
        Directory.CreateDirectory(folder);
        foreach (var (name, subject, withIdentifier) in new[] { ("alice", "First", true), ("bob", "Second", true), ("carol", "Third", false) })
        {
            if (!Missing(folder, $"{name}-cert.der")) continue;
            var (certificate, key) = Make(subject, withIdentifier);
            System.IO.File.WriteAllBytes(Path.Combine(folder, $"{name}-cert.der"), certificate.RawData);
            System.IO.File.WriteAllBytes(Path.Combine(folder, $"{name}-key.der"), key);
        }
        var alice = Certificate("alice");
        var bob = Certificate("bob");
        Seal(folder, "pubkey-aes256.txt", [new PdfRecipient(alice)], PdfCryptStrength.Aes256);
        Seal(folder, "pubkey-aes128.txt", [new PdfRecipient(alice)], PdfCryptStrength.Aes128);
        Seal(folder, "pubkey-two.txt",
            [new PdfRecipient(alice, PdfPermissions.Print | PdfPermissions.Copy), new PdfRecipient(bob, PdfPermissions.All, CanChangeEncryption: true)],
            PdfCryptStrength.Aes256);

        // The same content as pubkey-aes256.txt, sealed the other ways EnvelopedCms can: other content ciphers, OAEP,
        // a key identifier (with and without the extension in the certificate), and bytes after the entry.
        var recipient = new CmsRecipient(Certificate("alice", withKey: false));
        const string rc2 = "1.2.840.113549.3.2", tripleDes = "1.2.840.113549.3.7";
        Variant(folder, "pubkey-rc2.txt", "alice", content => Envelope(content, new AlgorithmIdentifier(new Oid(rc2), 128), recipient));
        Variant(folder, "pubkey-3des.txt", "alice", content => Envelope(content, new AlgorithmIdentifier(new Oid(tripleDes)), recipient));
        Variant(folder, "pubkey-oaep.txt", "alice", content => Envelope(content, Aes256,
            new CmsRecipient(SubjectIdentifierType.IssuerAndSerialNumber, Certificate("alice", withKey: false), RSAEncryptionPadding.OaepSHA256)));
        Variant(folder, "pubkey-keyid.txt", "alice", content => Envelope(content, Aes256,
            new CmsRecipient(SubjectIdentifierType.SubjectKeyIdentifier, Certificate("alice", withKey: false))));
        Variant(folder, "pubkey-keyid-plain.txt", "carol", content => Envelope(content, Aes256,
            new CmsRecipient(SubjectIdentifierType.SubjectKeyIdentifier, Certificate("carol", withKey: false))));
        Variant(folder, "pubkey-trailing.txt", "alice", content => [.. Envelope(content, Aes256, recipient), 0, 0]);
    }

    private static readonly AlgorithmIdentifier Aes256 = new(new Oid("2.16.840.1.101.3.4.1.42"));

    private static bool Missing(string folder, string name) => !System.IO.File.Exists(Path.Combine(folder, name));

    // As PublicKeyFiles.Certificate, but the private key stays exportable, as PKCS#1.
    private static (X509Certificate2 Certificate, byte[] Key) Make(string name, bool withIdentifier)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest($"CN={name}", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyEncipherment | X509KeyUsageFlags.DataEncipherment, true));
        if (withIdentifier) request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
        using var made = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
        return (X509CertificateLoader.LoadCertificate(made.RawData), rsa.ExportRSAPrivateKey());
    }

    private static void Seal(string folder, string name, IReadOnlyList<PdfRecipient> recipients, PdfCryptStrength strength)
    {
        if (!Missing(folder, name)) return;
        var security = PdfSecurity.CreatePublicKey(recipients, strength);
        string text = security.Dictionary + "\n" + Hex(security.EncryptString(4, 0, Secret)) + "\n";
        System.IO.File.WriteAllBytes(Path.Combine(folder, name), Encoding.ASCII.GetBytes(text));
    }

    private static byte[] Envelope(byte[] content, AlgorithmIdentifier cipher, CmsRecipient recipient)
    {
        var cms = new EnvelopedCms(new ContentInfo(content), cipher);
        cms.Encrypt(recipient);
        return cms.Encode();
    }

    // pubkey-aes256.txt with its one entry swapped for what `seal` makes of the entry's content, and the string
    // enciphered again under the key that gives for `holder`.
    private static void Variant(string folder, string name, string holder, Func<byte[], byte[]> seal)
    {
        if (!Missing(folder, name)) return;
        string line = Encoding.ASCII.GetString(File("pubkey-aes256.txt")).Split('\n')[0];
        var (dictionary, _) = Sealed("pubkey-aes256.txt");
        var filter = (PdfDictionary)((PdfDictionary)dictionary["CF"]!)[((PdfName)dictionary["StmF"]!).Value]!;
        byte[] entry = ((PdfString)((PdfArray)filter["Recipients"]!).Items[0]).Bytes;
        var cms = new EnvelopedCms();
        cms.Decode(entry);
        cms.Decrypt(new X509Certificate2Collection(Certificate("alice")));
        line = line.Replace(Hex(entry), Hex(seal(cms.ContentInfo.Content)), StringComparison.Ordinal);
        var changed = (PdfDictionary)new PdfLexer(new PdfArrayBytes(Encoding.ASCII.GetBytes(line))).ReadObject();
        var security = PdfSecurity.OpenPublicKey(changed, Certificate(holder))!;
        string text = line + "\n" + Hex(security.EncryptString(4, 0, Secret)) + "\n";
        System.IO.File.WriteAllBytes(Path.Combine(folder, name), Encoding.ASCII.GetBytes(text));
    }
}
