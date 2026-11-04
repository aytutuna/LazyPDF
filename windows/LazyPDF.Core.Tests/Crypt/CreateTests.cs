using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class CreateTests
{
    private static readonly byte[] Id = SyntheticEncryption.Id;

    // The dictionary as a file holds it: written out and read back.
    private static PdfDictionary Reparsed(PdfSecurity security) =>
        (PdfDictionary)new PdfLexer(new PdfArrayBytes(Encoding.ASCII.GetBytes(security.Dictionary.ToString()))).ReadObject();

    [Theory]
    [InlineData(PdfCryptStrength.Aes256, 6)]
    [InlineData(PdfCryptStrength.Aes128, 4)]
    public void CreatedFileOpensWithEachPassword(PdfCryptStrength strength, int revision)
    {
        var created = PdfSecurity.Create("user", "owner", PdfPermissions.Print | PdfPermissions.Copy, strength, Id);
        var dictionary = Reparsed(created);

        var user = PdfSecurity.Open(dictionary, Id, "user");
        var owner = PdfSecurity.Open(dictionary, Id, "owner");

        Assert.Equal(revision, created.Revision);
        Assert.NotNull(user);
        Assert.False(user.OpenedAsOwner);
        Assert.Equal(PdfPermissions.Print | PdfPermissions.Copy, user.Permissions);
        Assert.NotNull(owner);
        Assert.True(owner.OpenedAsOwner);
        Assert.Null(PdfSecurity.Open(dictionary, Id, "other"));
        Assert.Null(PdfSecurity.Open(dictionary, Id, ""));
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void ReaderDecryptsWhatTheCreatorEncrypted(PdfCryptStrength strength)
    {
        var created = PdfSecurity.Create("user", "owner", PdfPermissions.All, strength, Id);
        var reader = PdfSecurity.Open(Reparsed(created), Id, "user")!;
        byte[] plain = "BT /F1 12 Tf (text) Tj ET"u8.ToArray();

        Assert.Equal(plain, reader.DecryptStream(9, 0, created.EncryptStream(9, 0, plain, new PdfDictionary()), new PdfDictionary()));
        Assert.Equal(plain, reader.DecryptString(10, 0, created.EncryptString(10, 0, plain)));
        Assert.Equal(plain, created.DecryptString(10, 0, reader.EncryptString(10, 0, plain)));
    }

    [Fact]
    public void Aes256DictionaryHasTheR6Shape()
    {
        var dictionary = PdfSecurity.Create("u", "o", PdfPermissions.All, PdfCryptStrength.Aes256, Id).Dictionary;

        Assert.Equal(5, (int)((PdfNumber)dictionary["V"]!).Value);
        Assert.Equal(6, (int)((PdfNumber)dictionary["R"]!).Value);
        Assert.Equal(48, ((PdfString)dictionary["O"]!).Bytes.Length);
        Assert.Equal(48, ((PdfString)dictionary["U"]!).Bytes.Length);
        Assert.Equal(32, ((PdfString)dictionary["OE"]!).Bytes.Length);
        Assert.Equal(32, ((PdfString)dictionary["UE"]!).Bytes.Length);
        Assert.Equal(16, ((PdfString)dictionary["Perms"]!).Bytes.Length);
        Assert.Equal("StdCF", ((PdfName)dictionary["StmF"]!).Value);
    }

    [Fact]
    public void ReservedBitsOfPAreSet()
    {
        var dictionary = PdfSecurity.Create("u", "o", PdfPermissions.None, PdfCryptStrength.Aes128, Id).Dictionary;

        int p = (int)((PdfNumber)dictionary["P"]!).Integer!.Value;
        Assert.Equal(unchecked((int)0xFFFFF0C0), p);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void EveryPermissionSurvivesTheTrip(PdfCryptStrength strength)
    {
        foreach (var flag in Enum.GetValues<PdfPermissions>().Where(f => f != PdfPermissions.None && f != PdfPermissions.All))
        {
            var created = PdfSecurity.Create("u", "o", flag, strength, Id);

            Assert.Equal(flag, PdfSecurity.Open(Reparsed(created), Id, "u")!.Permissions);
        }
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void EmptyOwnerPasswordIsReplacedByUnknownBytes(PdfCryptStrength strength)
    {
        var created = PdfSecurity.Create("user", "", PdfPermissions.None, strength, Id);
        var dictionary = Reparsed(created);

        Assert.Null(PdfSecurity.Open(dictionary, Id, ""));
        Assert.False(PdfSecurity.Open(dictionary, Id, "user")!.OpenedAsOwner);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void EmptyUserPasswordOpensForAnyone(PdfCryptStrength strength)
    {
        var created = PdfSecurity.Create("", "owner", PdfPermissions.Print, strength, Id);
        var dictionary = Reparsed(created);

        var reader = PdfSecurity.Open(dictionary, Id, null)!;
        Assert.False(reader.OpenedAsOwner);
        Assert.Equal(PdfPermissions.Print, reader.Permissions);
        Assert.True(PdfSecurity.Open(dictionary, Id, "owner")!.OpenedAsOwner);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void SameSeedGivesTheSameFile(PdfCryptStrength strength)
    {
        var a = PdfSecurity.Create("u", "o", PdfPermissions.All, strength, Id, new Random(11));
        var b = PdfSecurity.Create("u", "o", PdfPermissions.All, strength, Id, new Random(11));
        var c = PdfSecurity.Create("u", "o", PdfPermissions.All, strength, Id, new Random(12));
        byte[] plain = "abc"u8.ToArray();

        Assert.Equal(a.Dictionary.ToString(), b.Dictionary.ToString());
        Assert.Equal(a.EncryptString(1, 0, plain), b.EncryptString(1, 0, plain));
        Assert.NotEqual(a.EncryptString(1, 0, plain), a.EncryptString(1, 0, plain));
        if (strength == PdfCryptStrength.Aes256) Assert.NotEqual(a.Dictionary.ToString(), c.Dictionary.ToString());
    }

    [Fact]
    public void UnseededCreatesDiffer()
    {
        var a = PdfSecurity.Create("u", "o", PdfPermissions.All, PdfCryptStrength.Aes256, Id);
        var b = PdfSecurity.Create("u", "o", PdfPermissions.All, PdfCryptStrength.Aes256, Id);

        Assert.NotEqual(a.Dictionary.ToString(), b.Dictionary.ToString());
    }

    [Fact]
    public void DefaultStrengthIsAes256()
    {
        Assert.Equal(PdfCryptStrength.Aes256, default);
    }

    [Fact]
    public void Aes128KeyDependsOnTheId()
    {
        var created = PdfSecurity.Create("u", "o", PdfPermissions.All, PdfCryptStrength.Aes128, Id);

        Assert.Null(PdfSecurity.Open(Reparsed(created), [9, 9, 9], "u"));
    }

    [Fact]
    public void ComposedAndDecomposedPasswordsBothOpenAes256()
    {
        var created = PdfSecurity.Create("été", "o", PdfPermissions.All, PdfCryptStrength.Aes256, Id);
        var dictionary = Reparsed(created);

        Assert.NotNull(PdfSecurity.Open(dictionary, Id, "été"));
        Assert.NotNull(PdfSecurity.Open(dictionary, Id, "été"));
    }

    [Fact]
    public void AnOpenedFileKeepsItsOwnDictionary()
    {
        var created = PdfSecurity.Create("u", "o", PdfPermissions.All, PdfCryptStrength.Aes256, Id);
        var dictionary = Reparsed(created);

        Assert.Same(dictionary, PdfSecurity.Open(dictionary, Id, "u")!.Dictionary);
    }
}
