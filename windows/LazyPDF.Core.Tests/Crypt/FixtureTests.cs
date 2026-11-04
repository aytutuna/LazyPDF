using Xunit;

namespace LazyPDF.Core.Tests;

public class FixtureTests
{
    // The crypt-* files are pypdf's, user "secret" and owner "owner".
    [Theory]
    [InlineData("crypt-rc4-40.pdf", 2)]
    [InlineData("crypt-aes128.pdf", 4)]
    [InlineData("crypt-aes256-r5.pdf", 5)]
    [InlineData("crypt-aes256.pdf", 6)]
    public void UserPasswordOpensAndDecryptsTheContent(string name, int revision)
    {
        var file = EncryptedFixture.Load(name);
        var security = PdfSecurity.Open(file.Encrypt, file.Id, "secret");

        Assert.NotNull(security);
        Assert.False(security.OpenedAsOwner);
        Assert.Equal(revision, security.Revision);
        var plain = security.DecryptStream(4, 0, file.Content, file.ContentDictionary);
        Assert.Equal(EncryptedFixture.PlainContent, System.Text.Encoding.ASCII.GetString(plain));
    }

    [Theory]
    [InlineData("crypt-rc4-40.pdf")]
    [InlineData("crypt-aes128.pdf")]
    [InlineData("crypt-aes256-r5.pdf")]
    [InlineData("crypt-aes256.pdf")]
    public void OwnerPasswordOpensAsOwner(string name)
    {
        var file = EncryptedFixture.Load(name);
        var security = PdfSecurity.Open(file.Encrypt, file.Id, "owner");

        Assert.NotNull(security);
        Assert.True(security.OpenedAsOwner);
        var plain = security.DecryptStream(4, 0, file.Content, file.ContentDictionary);
        Assert.Equal(EncryptedFixture.PlainContent, System.Text.Encoding.ASCII.GetString(plain));
    }

    [Theory]
    [InlineData("locked.pdf")]
    [InlineData("crypt-rc4-40.pdf")]
    [InlineData("crypt-aes128.pdf")]
    [InlineData("crypt-aes256-r5.pdf")]
    [InlineData("crypt-aes256.pdf")]
    public void WrongOrMissingPasswordGivesNull(string name)
    {
        var file = EncryptedFixture.Load(name);

        Assert.Null(PdfSecurity.Open(file.Encrypt, file.Id, "Secret"));
        Assert.Null(PdfSecurity.Open(file.Encrypt, file.Id, ""));
        Assert.Null(PdfSecurity.Open(file.Encrypt, file.Id, null));
    }

    [Theory]
    [InlineData("owner-only-rc4.pdf", 3)]
    [InlineData("owner-only-aes.pdf", 4)]
    public void OwnerOnlyFilesOpenWithTheEmptyPassword(string name, int revision)
    {
        var file = EncryptedFixture.Load(name);

        foreach (string? empty in new[] { null, "" })
        {
            var security = PdfSecurity.Open(file.Encrypt, file.Id, empty);
            Assert.NotNull(security);
            Assert.False(security.OpenedAsOwner);
            Assert.Equal(revision, security.Revision);
            var plain = security.DecryptStream(4, 0, file.Content, file.ContentDictionary);
            Assert.Equal(EncryptedFixture.PlainContent, System.Text.Encoding.ASCII.GetString(plain));
        }
        Assert.True(PdfSecurity.Open(file.Encrypt, file.Id, "owner")!.OpenedAsOwner);
    }

    // RC4-128 (V 2 R 3) with one password for both roles, so it opens as owner.
    [Fact]
    public void LockedFileOpensWithItsPassword()
    {
        var file = EncryptedFixture.Load("locked.pdf");
        var security = PdfSecurity.Open(file.Encrypt, file.Id, "secret")!;

        Assert.True(security.OpenedAsOwner);
        Assert.Equal(3, security.Revision);
        var plain = security.DecryptStream(4, 0, file.Content, file.ContentDictionary);
        Assert.Equal(EncryptedFixture.PlainContent, System.Text.Encoding.ASCII.GetString(plain));
        Assert.Null(PdfSecurity.Open(file.Encrypt, file.Id, ""));
    }

    [Fact]
    public void PermissionsComeFromP()
    {
        var file = EncryptedFixture.Load("locked.pdf");
        var security = PdfSecurity.Open(file.Encrypt, file.Id, "secret")!;

        Assert.Equal(PdfPermissions.All, security.Permissions);
        Assert.True(security.EncryptMetadata);
    }

    [Fact]
    public void WrongIdFailsTheLegacyCheck()
    {
        var file = EncryptedFixture.Load("locked.pdf");

        Assert.Null(PdfSecurity.Open(file.Encrypt, [1, 2, 3], "secret"));
    }
}
