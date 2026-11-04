using Xunit;

namespace LazyPDF.Core.Tests;

public class RevisionTests
{
    private static readonly byte[] Id = SyntheticEncryption.Id;

    // V, R, key bits, crypt filter method (null before V 4 and for the cipher of V 5).
    public static TheoryData<int, int, int, string?> Cases => new()
    {
        { 1, 2, 40, null },
        { 2, 3, 128, null },
        { 2, 3, 64, null },
        { 4, 4, 128, "V2" },
        { 4, 4, 128, "AESV2" },
        { 5, 5, 256, "AESV3" },
        { 5, 6, 256, "AESV3" },
    };

    private static BuiltEncryption Build(int v, int r, int bits, string? cfm, string user, string owner) =>
        v == 5 ? SyntheticEncryption.Modern(r, user, owner) : SyntheticEncryption.Legacy(v, r, bits, user, owner, cfm: cfm);

    private static byte[] Stored(BuiltEncryption built, string? cfm, int number, int generation, byte[] plain) => cfm switch
    {
        "AESV3" => SyntheticEncryption.StoreAes256(built.FileKey, plain),
        "AESV2" => SyntheticEncryption.StoreAes128(built.FileKey, number, generation, plain),
        _ => SyntheticEncryption.StoreRc4(built.FileKey, number, generation, plain),
    };

    [Theory]
    [MemberData(nameof(Cases))]
    public void UserAndOwnerPasswordsOpen(int v, int r, int bits, string? cfm)
    {
        var built = Build(v, r, bits, cfm, "user pw", "owner pw");

        var user = PdfSecurity.Open(built.Dictionary, Id, "user pw");
        var owner = PdfSecurity.Open(built.Dictionary, Id, "owner pw");

        Assert.NotNull(user);
        Assert.False(user.OpenedAsOwner);
        Assert.Equal(r, user.Revision);
        Assert.NotNull(owner);
        Assert.True(owner.OpenedAsOwner);
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void WrongPasswordsGiveNull(int v, int r, int bits, string? cfm)
    {
        var built = Build(v, r, bits, cfm, "user pw", "owner pw");

        Assert.Null(PdfSecurity.Open(built.Dictionary, Id, "user"));
        Assert.Null(PdfSecurity.Open(built.Dictionary, Id, "user pw "));
        Assert.Null(PdfSecurity.Open(built.Dictionary, Id, ""));
        Assert.Null(PdfSecurity.Open(built.Dictionary, Id, null));
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void EmptyUserPasswordOpensWithNullOrEmpty(int v, int r, int bits, string? cfm)
    {
        var built = Build(v, r, bits, cfm, "", "owner pw");

        Assert.False(PdfSecurity.Open(built.Dictionary, Id, null)!.OpenedAsOwner);
        Assert.False(PdfSecurity.Open(built.Dictionary, Id, "")!.OpenedAsOwner);
        Assert.True(PdfSecurity.Open(built.Dictionary, Id, "owner pw")!.OpenedAsOwner);
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void DecryptsWhatAWriterStored(int v, int r, int bits, string? cfm)
    {
        var built = Build(v, r, bits, cfm, "u", "o");
        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;
        byte[] plain = "(Hello) 0 0 Td"u8.ToArray();

        Assert.Equal(plain, security.DecryptString(12, 0, Stored(built, cfm, 12, 0, plain)));
        Assert.Equal(plain, security.DecryptStream(300, 2, Stored(built, cfm, 300, 2, plain), new PdfDictionary()));
        Assert.Equal(plain, security.DecryptString(70000, 0, Stored(built, cfm, 70000, 0, plain)));
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void EncryptThenDecryptRoundTrips(int v, int r, int bits, string? cfm)
    {
        var built = Build(v, r, bits, cfm, "u", "o");
        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;
        byte[] big = new byte[100_000];
        new Random(5).NextBytes(big);

        foreach (byte[] plain in new[] { [], [1], big[..16], big[..17], big })
        {
            byte[] stream = security.EncryptStream(8, 0, plain, new PdfDictionary());
            Assert.Equal(plain, security.DecryptStream(8, 0, stream, new PdfDictionary()));
            byte[] text = security.EncryptString(9, 1, plain);
            Assert.Equal(plain, security.DecryptString(9, 1, text));
        }
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void EncryptedFormMatchesWhatTheSpecProduces(int v, int r, int bits, string? cfm)
    {
        var built = Build(v, r, bits, cfm, "u", "o");
        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;
        byte[] plain = "same bytes"u8.ToArray();

        byte[] stored = security.EncryptString(21, 0, plain);

        if (cfm is null or "V2")
        {
            Assert.Equal(Stored(built, cfm, 21, 0, plain), stored);
        }
        else
        {
            // AES takes a random IV, so only the size is fixed: the IV and one padded block.
            Assert.Equal(32, stored.Length);
            Assert.NotEqual(plain, stored[16..26]);
        }
    }

    [Theory]
    [InlineData(1, 2, 40, null)]
    [InlineData(4, 4, 128, "V2")]
    [InlineData(4, 4, 128, "AESV2")]
    public void ObjectsAreKeyedByNumberAndGeneration(int v, int r, int bits, string? cfm)
    {
        var built = Build(v, r, bits, cfm, "u", "o");
        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;
        byte[] plain = "0123456789abcdef0123"u8.ToArray();
        byte[] stored = Stored(built, cfm, 4, 0, plain);

        Assert.Equal(plain, security.DecryptString(4, 0, stored));
        Assert.NotEqual(plain, security.DecryptString(5, 0, stored));
        Assert.NotEqual(plain, security.DecryptString(4, 1, stored));
    }

    [Fact]
    public void PermissionsAreReadFromP()
    {
        int p = unchecked((int)0xFFFFF0C0) | 4 | 256;
        var built = SyntheticEncryption.Legacy(2, 3, 128, "u", "o", p);

        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;

        Assert.Equal(PdfPermissions.Print | PdfPermissions.FillForms, security.Permissions);
    }

    [Fact]
    public void PermissionsOfAnOwnerAreStillTheFilesFlags()
    {
        var built = SyntheticEncryption.Modern(6, "u", "o", unchecked((int)0xFFFFF0C0) | 16);

        var owner = PdfSecurity.Open(built.Dictionary, Id, "o")!;

        Assert.True(owner.OpenedAsOwner);
        Assert.Equal(PdfPermissions.Copy, owner.Permissions);
    }

    [Fact]
    public void PAsAnUnsignedNumberIsTheSameAsNegative()
    {
        var built = SyntheticEncryption.Legacy(2, 3, 128, "u", "o");
        built.Dictionary["P"] = new PdfNumber("4294967292");

        var security = PdfSecurity.Open(built.Dictionary, Id, "u");

        Assert.NotNull(security);
        Assert.Equal(PdfPermissions.All, security.Permissions);
    }

    [Fact]
    public void EncryptMetadataFalseChangesTheKeyAndIsReported()
    {
        var built = SyntheticEncryption.Legacy(4, 4, 128, "u", "o", cfm: "AESV2", encryptMetadata: false);

        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;

        Assert.False(security.EncryptMetadata);
        byte[] plain = "text"u8.ToArray();
        Assert.Equal(plain, security.DecryptString(3, 0, SyntheticEncryption.StoreAes128(built.FileKey, 3, 0, plain)));
    }

    [Fact]
    public void EncryptMetadataIsIgnoredBeforeR4()
    {
        var built = SyntheticEncryption.Legacy(2, 3, 128, "u", "o");
        built.Dictionary["EncryptMetadata"] = new PdfBoolean(false);

        Assert.True(PdfSecurity.Open(built.Dictionary, Id, "u")!.EncryptMetadata);
    }

    [Fact]
    public void StringsAndStreamsCanUseDifferentFilters()
    {
        var built = SyntheticEncryption.Legacy(4, 4, 128, "u", "o", cfm: "AESV2", strF: "StdCF", stmF: "Rc4CF");
        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;
        byte[] plain = "mixed"u8.ToArray();

        Assert.Equal(plain, security.DecryptString(6, 0, SyntheticEncryption.StoreAes128(built.FileKey, 6, 0, plain)));
        Assert.Equal(plain, security.DecryptStream(6, 0, SyntheticEncryption.StoreRc4(built.FileKey, 6, 0, plain), new PdfDictionary()));
    }

    [Fact]
    public void IdentityFiltersLeaveDataAlone()
    {
        var built = SyntheticEncryption.Legacy(4, 4, 128, "u", "o", cfm: "AESV2", strF: "Identity", stmF: "Identity");
        var security = PdfSecurity.Open(built.Dictionary, Id, "u")!;
        byte[] plain = "clear"u8.ToArray();

        Assert.Equal(plain, security.DecryptString(1, 0, plain));
        Assert.Equal(plain, security.DecryptStream(1, 0, plain, new PdfDictionary()));
        Assert.Equal(plain, security.EncryptString(1, 0, plain));
    }

    [Fact]
    public void PasswordOutsideLatin1FailsCleanlyOnLegacy()
    {
        var built = SyntheticEncryption.Legacy(2, 3, 128, "u", "o");

        Assert.Null(PdfSecurity.Open(built.Dictionary, Id, "中文"));
    }

    [Fact]
    public void Latin1PasswordOpensLegacyFiles()
    {
        var built = SyntheticEncryption.Legacy(2, 3, 128, "café", "o");

        Assert.NotNull(PdfSecurity.Open(built.Dictionary, Id, "café"));
    }

    [Theory]
    [InlineData(5)]
    [InlineData(6)]
    public void ModernPasswordsAreSaslPrepared(int r)
    {
        // The file holds the prepared form "a b"; the typed one has a soft hyphen and a no-break space.
        var built = SyntheticEncryption.Modern(r, "a b", "o");

        Assert.NotNull(PdfSecurity.Open(built.Dictionary, Id, "a­ b"));
    }

    [Fact]
    public void ModernPasswordLongerThan127BytesIsCut()
    {
        string stored = new('x', 127);
        var built = SyntheticEncryption.Modern(6, stored, "o");

        Assert.NotNull(PdfSecurity.Open(built.Dictionary, Id, stored + "yyyy"));
    }
}
