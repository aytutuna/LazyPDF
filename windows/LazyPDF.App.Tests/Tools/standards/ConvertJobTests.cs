using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Standards;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What the PDF/A panel takes from a tab, and the words it uses for the result.
public sealed class ConvertJobTests
{
    private static DocumentTab TabOf(byte[] bytes, string title = "Quarterly report.pdf", string? password = null, X509Certificate2? certificate = null)
    {
        var session = certificate is not null ? PdfEditSession.Open(bytes, certificate) : PdfEditSession.Open(bytes, password);
        return new DocumentTab(session, new FakeRenderer(), null, title, password, certificate: certificate);
    }

    private static X509Certificate2 NewCertificate()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Alice", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyEncipherment | X509KeyUsageFlags.DataEncipherment, critical: false));
        using var made = request.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        return X509CertificateLoader.LoadPkcs12(made.Export(X509ContentType.Pfx), null);
    }

    [Fact]
    public async Task ATabIsConvertedOffTheUiThreadFromTheBytesItHadWhenTheJobWasMade()
    {
        var tab = TabOf(Pdfs.Text());
        var job = new ConvertJob(tab);
        Pdfs.Retitle(tab.Session, "Changed after");
        tab.Commit("Title");

        var made = await Task.Run(() => job.Run(PdfALevel.A2b, new FakeFonts()));

        Assert.NotNull(made.Bytes);
        Assert.NotEqual("Changed after", DocumentMetadata.Read(PdfDocument.Open(made.Bytes)).Title);
    }

    private static byte[] Protected()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var security = PdfSecurity.Create("open", "owner", PdfPermissions.Print | PdfPermissions.Modify, PdfCryptStrength.Aes256, document.FirstId ?? []);
        return document.SaveRewrite(new PdfSaveOptions(Security: security));
    }

    [Fact]
    public void AFileOpenedWithTheOwnerPasswordIsConvertedWithIt()
    {
        var tab = TabOf(Protected(), password: "owner");

        var made = new ConvertJob(tab).Run(PdfALevel.A2b, new FakeFonts());

        Assert.NotNull(made.Bytes);
        Assert.False(PdfDocument.Open(made.Bytes).IsEncrypted);
    }

    [Fact]
    public void AFileOpenedWithOnlyTheUserPasswordIsRefusedNotThrown()
    {
        var tab = TabOf(Protected(), password: "open");

        var made = new ConvertJob(tab).Run(PdfALevel.A2b, new FakeFonts());

        Assert.Null(made.Bytes);
        Assert.Equal(PdfAText.NoRights, made.Refusal);
    }

    [Fact]
    public void AFileOpenedWithACertificateIsConvertedNotRefusedAsUnreadable()
    {
        var alice = NewCertificate();
        var security = PdfSecurity.CreatePublicKey([new PdfRecipient(alice)], PdfCryptStrength.Aes256);
        var tab = TabOf(PdfDocument.Open(Pdfs.Text()).SaveRewrite(new PdfSaveOptions(false, security)), certificate: alice);

        var made = new ConvertJob(tab).Run(PdfALevel.A2b, new FakeFonts());

        Assert.NotNull(made.Bytes);
        Assert.False(PdfDocument.Open(made.Bytes).IsEncrypted);
    }

    [Fact]
    public void WhatConvertingCostsIsSaidBeforeItIsDone()
    {
        Assert.Equal("", StandardsText.Losses(false, false));
        Assert.Contains("signatures", StandardsText.Losses(true, false));
        Assert.Contains("password", StandardsText.Losses(false, true));
        Assert.Contains("signatures", StandardsText.Losses(true, true));
        Assert.Contains("password", StandardsText.Losses(true, true));
    }

    [Fact]
    public void TheResultListsEveryChangeAndOnlyClaimsPassingChecksWhenItIsClean()
    {
        var clean = new PdfAConversion([1], null, [], [PdfAText.EncryptionRemoved, PdfAText.SignaturesBroken, PdfAText.LayersRemoved]);
        var broken = new PdfAConversion([1], null, [new PdfAIssue("6.1.3", PdfAText.Trailer, "The trailer has no /ID.")], [PdfAText.AttachmentsRemoved(2)]);

        string passed = StandardsText.ConvertedText(clean, PdfALevel.A2b);
        string still = StandardsText.ConvertedText(broken, PdfALevel.A2b);

        Assert.Contains("passes Lazy PDF's checks for PDF/A-2b", passed);
        Assert.Contains(PdfAText.EncryptionRemoved, passed);
        Assert.Contains(PdfAText.SignaturesBroken, passed);
        Assert.Contains(PdfAText.LayersRemoved, passed);
        Assert.Contains("still breaks 1 rules", still);
        Assert.Contains(PdfAText.AttachmentsRemoved(2), still);
        Assert.NotEqual(StandardsText.ConvertedTitle(clean), StandardsText.ConvertedTitle(broken));
        Assert.DoesNotContain("PDF/A-2b", StandardsText.ConvertedTitle(broken));
    }

    [Fact]
    public void TheNewTabNameKeepsTheFileNameWhenItIsCutAtASlash()
    {
        string clean = StandardsText.ConvertedName("Quarterly report.pdf", PdfALevel.A2b, true);
        string broken = StandardsText.ConvertedName(clean, PdfALevel.A3b, false);

        Assert.Equal("Quarterly report (PDF-A-2b).pdf", clean);
        Assert.Equal("Quarterly report (PDF-A-2b) (converted).pdf", broken);
        Assert.Equal("Quarterly report (PDF-A-2b)", Path.GetFileNameWithoutExtension(clean));
    }

    [Fact]
    public async Task ACopyOfATabIsReadOnTheWorkerFromTheBytesOfTheMomentItWasAskedFor()
    {
        var tab = TabOf(Pdfs.Text());
        var open = OpenCopy.Of(tab);
        Pdfs.Retitle(tab.Session, "Newer");
        tab.Commit("Title");

        using var copy = await Task.Run(open);

        Assert.NotEqual("Newer", DocumentMetadata.Read(copy).Title);
        Assert.False(ReferenceEquals(copy, tab.Document));
    }
}
