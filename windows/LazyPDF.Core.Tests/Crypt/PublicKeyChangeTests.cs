using Xunit;

namespace LazyPDF.Core.Tests;

public class PublicKeyChangeTests
{
    private static readonly byte[] Id = new byte[16];

    private static byte[] Passworded(PdfCryptStrength strength = PdfCryptStrength.Aes256) =>
        PdfDocument.Open(PublicKeyFiles.Plain()).SaveRewrite(new PdfSaveOptions(
            Security: PdfSecurity.Create("user", "owner", PdfPermissions.Print, strength, Id), DocumentId: Id));

    private static PdfSaveOptions ToRecipients(params PdfRecipient[] recipients) =>
        new(Security: PdfSecurity.CreatePublicKey(recipients, PdfCryptStrength.Aes256));

    private static PdfSaveOptions ToPassword() =>
        new(Security: PdfSecurity.Create("new", "newowner", PdfPermissions.All, PdfCryptStrength.Aes256, Id), DocumentId: Id);

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void OwnerMovesAPasswordFileToCertificates(PdfCryptStrength strength)
    {
        using var owner = PdfDocument.Open(Passworded(strength), "owner");

        var moved = owner.SaveRewrite(ToRecipients(new PdfRecipient(PublicKeyFiles.Alice)));

        using var document = PdfDocument.Open(moved, PublicKeyFiles.Alice);
        Assert.True(document.Security!.IsPublicKey);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
        Assert.Equal(PdfReadProblem.CertificateRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(moved, "owner")).Problem);
    }

    [Fact]
    public void OwnerMovesACertificateFileToAPassword()
    {
        using var owner = PdfDocument.Open(PublicKeyFiles.Seal([new PdfRecipient(PublicKeyFiles.Alice, CanChangeEncryption: true)]), PublicKeyFiles.Alice);

        var moved = owner.SaveRewrite(ToPassword());

        using var document = PdfDocument.Open(moved, "new");
        Assert.False(document.Security!.IsPublicKey);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
    }

    [Fact]
    public void OwnerRemovesEncryptionFromBothKinds()
    {
        using var password = PdfDocument.Open(Passworded(), "owner");
        using var certificate = PdfDocument.Open(PublicKeyFiles.Seal([new PdfRecipient(PublicKeyFiles.Alice, CanChangeEncryption: true)]), PublicKeyFiles.Alice);

        foreach (var open in new[] { password, certificate })
        {
            byte[] plain = open.SaveRewrite();

            using var document = PdfDocument.Open(plain);
            Assert.False(document.IsEncrypted);
            Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(document));
            using var pig = UglyToad.PdfPig.PdfDocument.Open(plain);
            Assert.Contains("Sealed for recipients", pig.GetPage(1).Text);
        }
    }

    [Fact]
    public void OwnerChangesTheRecipientList()
    {
        using var owner = PdfDocument.Open(PublicKeyFiles.Seal([new PdfRecipient(PublicKeyFiles.Alice, CanChangeEncryption: true)]), PublicKeyFiles.Alice);

        var moved = owner.SaveRewrite(ToRecipients(new PdfRecipient(PublicKeyFiles.Bob)));

        using var bob = PdfDocument.Open(moved, PublicKeyFiles.Bob);
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(bob));
        Assert.Equal(PdfReadProblem.CertificateRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(moved, PublicKeyFiles.Alice)).Problem);
    }

    [Fact]
    public void PlainFileMayBeEncryptedByAnyone()
    {
        using var plain = PdfDocument.Open(PublicKeyFiles.Plain());

        using var document = PdfDocument.Open(plain.SaveRewrite(ToRecipients(new PdfRecipient(PublicKeyFiles.Alice))), PublicKeyFiles.Alice);

        Assert.True(document.IsEncrypted);
    }

    [Fact]
    public void UserPasswordCannotChangeTheEncryption()
    {
        using var user = PdfDocument.Open(Passworded(), "user");

        Assert.False(user.Security!.OpenedAsOwner);
        Assert.Throws<PdfPermissionException>(() => user.SaveRewrite());
        Assert.Throws<PdfPermissionException>(() => user.SaveRewrite(ToPassword()));
        Assert.Throws<PdfPermissionException>(() => user.SaveRewrite(ToRecipients(new PdfRecipient(PublicKeyFiles.Alice))));
    }

    [Fact]
    public void RecipientWithoutOwnershipCannotChangeTheEncryption()
    {
        using var recipient = PdfDocument.Open(PublicKeyFiles.Seal([new PdfRecipient(PublicKeyFiles.Alice, PdfPermissions.Print)]), PublicKeyFiles.Alice);

        Assert.Throws<PdfPermissionException>(() => recipient.SaveRewrite());
        Assert.Throws<PdfPermissionException>(() => recipient.SaveRewrite(ToPassword()));
        Assert.Throws<PdfPermissionException>(() => recipient.SaveRewrite(ToRecipients(new PdfRecipient(PublicKeyFiles.Bob))));
    }

    [Fact]
    public void ReaderWithAllPermissionsMayChangeItBothWays()
    {
        using var recipient = PdfDocument.Open(PublicKeyFiles.Seal(PublicKeyFiles.Alice), PublicKeyFiles.Alice);
        using var user = PdfDocument.Open(PdfDocument.Open(PublicKeyFiles.Plain()).SaveRewrite(new PdfSaveOptions(
            Security: PdfSecurity.Create("user", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, Id), DocumentId: Id)), "user");

        Assert.False(PdfDocument.Open(recipient.SaveRewrite()).IsEncrypted);
        Assert.False(PdfDocument.Open(user.SaveRewrite(ToRecipients(new PdfRecipient(PublicKeyFiles.Bob))), PublicKeyFiles.Bob).Security!.OpenedAsOwner);
    }

    [Fact]
    public void KeepingTheFilesOwnHandlerIsAlwaysAllowed()
    {
        using var user = PdfDocument.Open(Passworded(), "user");
        using var recipient = PdfDocument.Open(PublicKeyFiles.Seal([new PdfRecipient(PublicKeyFiles.Alice, PdfPermissions.Print)]), PublicKeyFiles.Alice);

        using var again = PdfDocument.Open(user.SaveRewrite(new PdfSaveOptions(Security: user.Security)), "user");
        using var sealedAgain = PdfDocument.Open(recipient.SaveRewrite(new PdfSaveOptions(true, recipient.Security)), PublicKeyFiles.Alice);

        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(again));
        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(sealedAgain));
    }

    [Fact]
    public void RefusedSaveWritesNothingAndLeavesTheDocumentUsable()
    {
        using var user = PdfDocument.Open(Passworded(), "user");

        Assert.Throws<PdfPermissionException>(() => user.SaveRewrite());

        Assert.Contains(PublicKeyFiles.PageText, PublicKeyFiles.Content(user));
    }
}
