using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Tools.Protect;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Protect;

public sealed class ProtectWorkTests
{
    private static PdfDocument Plain(int pages = 2) => PdfDocument.Open(Pdfs.Text(pages));

    private static X509Certificate2 Certificate(string name, bool keepKey = true)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=" + name, rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyEncipherment, critical: true));
        using var made = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        var withKey = X509CertificateLoader.LoadPkcs12(made.Export(X509ContentType.Pfx, "x"), "x", X509KeyStorageFlags.Exportable);
        return keepKey ? withKey : X509CertificateLoader.LoadCertificate(withKey.RawData);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256, 6)]
    [InlineData(PdfCryptStrength.Aes128, 4)]
    public void APasswordOpensTheCopyAndNothingElseDoes(PdfCryptStrength strength, int revision)
    {
        byte[] bytes = ProtectWork.WithPassword(Plain(3), "open sesame", "open sesame", PdfPermissions.All, strength);

        using var opened = PdfDocument.Open(bytes, "open sesame");
        Assert.Equal(3, opened.Pages.Count);
        Assert.Equal(revision, opened.Security!.Revision);
        Assert.Equal(PdfReadProblem.PasswordRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(bytes, "wrong")).Problem);
        Assert.Equal(PdfReadProblem.PasswordRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(bytes)).Problem);
    }

    [Fact]
    public void LimitsWithoutAPasswordToOpenLetAnyoneReadButNotDoMore()
    {
        var allowed = (PermissionChoices.Everything with { Copy = false, Edit = false, Print = false, PrintHighQuality = true }).ToPermissions();

        byte[] bytes = ProtectWork.WithPassword(Plain(), "", "boss", allowed, PdfCryptStrength.Aes256);

        using var reader = PdfDocument.Open(bytes);
        Assert.False(reader.Security!.OpenedAsOwner);
        Assert.Equal(PdfPermissions.None, reader.Security.Permissions & (PdfPermissions.Copy | PdfPermissions.Modify | PdfPermissions.Print | PdfPermissions.PrintHighQuality));
        Assert.True(reader.Security.Permissions.HasFlag(PdfPermissions.Annotate));
        using var owner = PdfDocument.Open(bytes, "boss");
        Assert.True(owner.Security!.OpenedAsOwner);
    }

    [Fact]
    public void HighQualityPrintingNeedsPrintingToBeAllowed()
    {
        var withoutPrint = (PermissionChoices.Everything with { Print = false }).ToPermissions();
        var withPrint = PermissionChoices.Everything.ToPermissions();

        Assert.False(withoutPrint.HasFlag(PdfPermissions.PrintHighQuality));
        Assert.True(withPrint.HasFlag(PdfPermissions.PrintHighQuality));
        Assert.Equal(PdfPermissions.All, withPrint);
    }

    [Fact]
    public void ProtectionComesOffAgainWhenTheOwnerHoldsIt()
    {
        byte[] locked = ProtectWork.WithPassword(Plain(), "secret", "secret", PdfPermissions.All, PdfCryptStrength.Aes256);
        using var document = PdfDocument.Open(locked, "secret");

        byte[] open = ProtectWork.Remove(document);

        using var back = PdfDocument.Open(open);
        Assert.False(back.IsEncrypted);
        Assert.Equal(2, back.Pages.Count);
    }

    [Fact]
    public void ARestrictedFileOpenedWithoutTheOwnerPasswordCannotBeRewritten()
    {
        using var document = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print));

        Assert.True(ProtectWork.IsLockedAgainstChange(document));
        Assert.Throws<PdfPermissionException>(() => ProtectWork.Remove(document));
        Assert.Throws<PdfPermissionException>(() => ProtectWork.WithPassword(document, "new", "new", PdfPermissions.All, PdfCryptStrength.Aes256));
    }

    [Fact]
    public void TheOwnerPasswordLiftsTheLock()
    {
        using var document = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "owner");

        Assert.False(ProtectWork.IsLockedAgainstChange(document));
        using var back = PdfDocument.Open(ProtectWork.Remove(document));
        Assert.False(back.IsEncrypted);
    }

    [Fact]
    public void AFileThatRestrictsNothingIsNotLocked()
    {
        using var document = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.All));

        Assert.False(ProtectWork.IsLockedAgainstChange(document));
        Assert.False(ProtectWork.IsLockedAgainstChange(Plain()));
    }

    [Fact]
    public void ProtectingAgainReplacesTheOldPassword()
    {
        byte[] first = ProtectWork.WithPassword(Plain(), "one", "one", PdfPermissions.All, PdfCryptStrength.Aes256);
        using var document = PdfDocument.Open(first, "one");

        byte[] second = ProtectWork.WithPassword(document, "two", "two", PdfPermissions.All, PdfCryptStrength.Aes256);

        Assert.Throws<PdfReadException>(() => PdfDocument.Open(second, "one"));
        using var back = PdfDocument.Open(second, "two");
        Assert.Equal(2, back.Pages.Count);
    }

    [Fact]
    public void ACertificateHolderOpensTheCopy()
    {
        using var mine = Certificate("Me");
        using var theirs = Certificate("Them");
        var recipients = new[]
        {
            new Recipient(mine).ToPdfRecipient(PdfPermissions.All),
            new Recipient(X509CertificateLoader.LoadCertificate(theirs.RawData)).ToPdfRecipient(PdfPermissions.Print),
        };

        var (bytes, opener) = ProtectWork.ForRecipients(Plain(2), recipients, PdfCryptStrength.Aes256);

        Assert.Equal(mine.Thumbprint, opener!.Thumbprint);
        using var opened = PdfDocument.Open(bytes, mine);
        Assert.Equal(2, opened.Pages.Count);
        Assert.True(opened.Security!.IsPublicKey);
        Assert.True(opened.Security.OpenedAsOwner);
        Assert.Equal(PdfReadProblem.CertificateRequired, Assert.Throws<PdfReadException>(() => PdfDocument.Open(bytes, "password")).Problem);
    }

    [Fact]
    public void ACopyForOthersOnlyHasNoOneToOpenItHere()
    {
        using var theirs = Certificate("Them", keepKey: false);
        var recipients = new[] { new Recipient(X509CertificateLoader.LoadCertificate(theirs.RawData)).ToPdfRecipient(PdfPermissions.All) };

        var (bytes, opener) = ProtectWork.ForRecipients(Plain(2), recipients, PdfCryptStrength.Aes256);

        Assert.Null(opener);
        Assert.NotEmpty(bytes);
    }

    [Fact]
    public void AddingCommentsAlwaysAllowsFillingFormsAndReadingAloudIsNeverSwitchedOff()
    {
        var allowed = (PermissionChoices.Everything with { FillForms = false, Comment = true }).ToPermissions();
        var noComment = (PermissionChoices.Everything with { FillForms = false, Comment = false }).ToPermissions();

        Assert.True(allowed.HasFlag(PdfPermissions.FillForms));
        Assert.False(noComment.HasFlag(PdfPermissions.FillForms));
        Assert.True(noComment.HasFlag(PdfPermissions.ExtractForAccessibility));
    }

    [Fact]
    public void OnlyTheHolderOfAKeyOnThisComputerMayChangeTheProtectionLater()
    {
        using var mine = Certificate("Me");
        using var theirs = Certificate("Them", keepKey: false);

        Assert.True(new Recipient(mine).ToPdfRecipient(PdfPermissions.Print).CanChangeEncryption);
        Assert.False(new Recipient(theirs).ToPdfRecipient(PdfPermissions.Print).CanChangeEncryption);
    }

    [Theory]
    [InlineData("", "", false, "", false)]
    [InlineData("a", "a", false, "", true)]
    [InlineData("a", "b", false, "", false)]
    [InlineData("", "", true, "boss", true)]
    [InlineData("", "", true, "", false)]
    [InlineData("a", "a", true, "a", false)]
    [InlineData("a", "a", true, "b", true)]
    public void ThePasswordBoxesMustAgreeBeforeAnythingRuns(string open, string repeat, bool limited, string owner, bool expected) =>
        Assert.Equal(expected, ProtectWork.PasswordsAgree(open, repeat, limited, owner));

    [Fact]
    public async Task AProtectedCopyAsksForItsPasswordAndThenOpensAsADocumentThatNeedsAName()
    {
        using var f = new ViewModelFixture();
        byte[] bytes = ProtectWork.WithPassword(Plain(2), "secret", "secret", PdfPermissions.All, PdfCryptStrength.Aes256);

        await f.Vm.OpenNewAsync(bytes, "a protected.pdf");
        Assert.NotNull(f.Vm.PasswordRequest);
        await f.Vm.SubmitPasswordAsync("secret");

        var tab = f.Vm.ActiveDocument!;
        Assert.Equal(2, tab.PageCount);
        Assert.True(tab.Document.IsEncrypted);
        Assert.True(AppViewModel.NeedsName(tab));
    }
}
