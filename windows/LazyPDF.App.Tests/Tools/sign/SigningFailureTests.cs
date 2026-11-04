using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A signing that fails or is cancelled leaves the file as it was, and the panel only claims what the servers gave.
public sealed class SigningFailureTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 10, 9, 0, 0, TimeSpan.Zero);

    private sealed class Down : ISignatureTransport
    {
        public byte[]? Post(string url, string contentType, byte[] body) => null;

        public byte[]? Get(string url) => null;
    }

    private sealed class Cancelled : ISignatureTransport
    {
        public byte[]? Post(string url, string contentType, byte[] body) => throw new OperationCanceledException();

        public byte[]? Get(string url) => throw new OperationCanceledException();
    }

    private static X509Certificate2 Ada() => PdfDigitalId.Create("Ada Lovelace", null, Now.AddDays(-1), years: 2, keyBits: 2048);

    private static SignChoices Plain(X509Certificate2 certificate) =>
        new(certificate, null, 0, null, "", "", CertificationLevel.None, null, false);

    private static IReadOnlyList<SignatureReport> Reports(PdfEditSession session) =>
        PdfSignatureVerifier.Verify(session.Current.ToArray(), new SigningSettings { TrustWindowsStore = false }.Verify(null, null, Now));

    // A signer whose certificate names an OCSP responder, issued by an authority the file carries.
    private static (X509Certificate2 Signer, X509Certificate2 Authority) Issued()
    {
        using var authorityKey = RSA.Create(2048);
        var authorityRequest = new CertificateRequest("CN=Test Authority", authorityKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        authorityRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        var authority = authorityRequest.CreateSelfSigned(Now.AddDays(-30), Now.AddYears(5));

        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Grace Hopper", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        var writer = new AsnWriter(AsnEncodingRules.DER);
        using (writer.PushSequence())
        using (writer.PushSequence())
        {
            writer.WriteObjectIdentifier("1.3.6.1.5.5.7.48.1");
            writer.WriteCharacterString(UniversalTagNumber.IA5String, "http://ocsp.example/", new Asn1Tag(TagClass.ContextSpecific, 6));
        }
        request.CertificateExtensions.Add(new X509Extension("1.3.6.1.5.5.7.1.1", writer.Encode(), false));
        using var signed = request.Create(authority, Now.AddDays(-1), Now.AddYears(1), [1, 2, 3, 4]);
        return (signed.CopyWithPrivateKey(key), authority);
    }

    private static PdfEditSession SignedByGrace()
    {
        var (signer, ca) = Issued();
        var session = PdfEditSession.Open(Pdfs.Text());
        PdfSigner.Sign(session, new PdfSignRequest(signer, Now) { Chain = [ca], Fonts = new FakeFonts() });
        return session;
    }

    [Fact]
    public void ATimeStampThatFailsLeavesNoSignatureBehind()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());

        Assert.Throws<InvalidOperationException>(() =>
            CertificateSigning.Sign(session, Plain(ada) with { TimestampUrl = "https://tsa.example/stamp" }, new Down(), new FakeFonts(), Now));

        Assert.False(session.IsDirty);
        Assert.False(session.Document.IsSigned);
        Assert.Empty(PdfForm.Read(session.Document).Fields);
    }

    [Fact]
    public void SigningAgainAfterAFailureMakesOneGoodSignature()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());
        Assert.ThrowsAny<InvalidOperationException>(() =>
            CertificateSigning.Sign(session, Plain(ada) with { TimestampUrl = "https://tsa.example/stamp" }, new Down(), new FakeFonts(), Now));

        CertificateSigning.Sign(session, Plain(ada), new Down(), new FakeFonts(), Now);

        var report = Assert.Single(Reports(session));
        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
    }

    [Fact]
    public void AnEmptyFieldIsStillEmptyAfterAFailure()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());
        PdfForm.Read(session.Document).AddField(new FieldSpec(FieldKind.Signature, "Approval", 0, new PdfRect(72, 100, 200, 150)));
        session.Commit("Field");
        var choices = Plain(ada) with { Field = "Approval", TimestampUrl = "https://tsa.example/stamp" };

        Assert.ThrowsAny<InvalidOperationException>(() => CertificateSigning.Sign(session, choices, new Down(), new FakeFonts(), Now));

        Assert.Equal(["Approval"], CertificateSigning.EmptyFields(session.Document));
    }

    [Fact]
    public void ACancelledSigningLeavesTheFileAsItWas()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());

        Assert.Throws<OperationCanceledException>(() =>
            CertificateSigning.Sign(session, Plain(ada) with { TimestampUrl = "https://tsa.example/stamp" }, new Cancelled(), new FakeFonts(), Now));

        Assert.False(session.IsDirty);
        Assert.False(session.Document.IsSigned);
    }

    [Fact]
    public void ACancelledValidationLeavesNoPartOfItPending()
    {
        var session = SignedByGrace();
        int length = session.Current.Length;

        Assert.Throws<OperationCanceledException>(() => CertificateSigning.AddValidation(session, new Cancelled(), Now));

        Assert.Equal(length, session.Current.Length);
        Assert.False(session.Document.HasChanges);
    }

    [Fact]
    public void ValidationWithNoServerAddsCertificatesButIsNotProofOfRevocation()
    {
        var session = SignedByGrace();
        int length = session.Current.Length;
        var options = new SigningSettings { TrustWindowsStore = false }.Verify(null, null, Now);

        CertificateSigning.AddValidation(session, new Down(), Now);

        Assert.True(session.Current.Length > length);
        Assert.False(CertificateSigning.RevocationCovered(session.Current.ToArray(), options));
    }

    [Fact]
    public void AFileWithoutSignaturesIsNotCovered()
    {
        var options = new SigningSettings { TrustWindowsStore = false }.Verify(null, null, Now);

        Assert.True(CertificateSigning.RevocationCovered(Pdfs.Text(), options));
    }

    [Fact]
    public void OnlyAWebAddressIsATimeStampServer()
    {
        Assert.True(CertificateSigning.IsWebAddress(" https://timestamp.example/tsa "));
        Assert.True(CertificateSigning.IsWebAddress("http://timestamp.example"));
        Assert.False(CertificateSigning.IsWebAddress("timestamp.example"));
        Assert.False(CertificateSigning.IsWebAddress("http://"));
        Assert.False(CertificateSigning.IsWebAddress("ftp://timestamp.example"));
        Assert.False(CertificateSigning.IsWebAddress(""));
    }

    [Fact]
    public void AFileThatAllowsNothingCannotBeSigned()
    {
        var locked = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "");
        var form = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.FillForms), "");
        var owner = PdfDocument.Open(Pdfs.Restricted(PdfPermissions.Print), "owner");

        Assert.NotNull(CertificateSigning.Refusal(locked, newField: false));
        Assert.NotNull(CertificateSigning.Refusal(locked, newField: true));
        Assert.Null(CertificateSigning.Refusal(form, newField: false));
        Assert.NotNull(CertificateSigning.Refusal(form, newField: true));
        Assert.Null(CertificateSigning.Refusal(owner, newField: true));
        Assert.Null(CertificateSigning.Refusal(PdfDocument.Open(Pdfs.Text()), newField: true));
    }

    [Fact]
    public async Task ACancelWhileTheServerIsAnsweringStopsTheSigning()
    {
        using var cancel = new CancellationTokenSource();
        var transport = new CancellableTransport(new CancelsOnPost(cancel), cancel.Token);

        await Task.Run(() => Assert.Throws<OperationCanceledException>(() => transport.Post("http://x", "a/b", [])));
    }

    private sealed class CancelsOnPost(CancellationTokenSource source) : ISignatureTransport
    {
        public byte[]? Post(string url, string contentType, byte[] body)
        {
            source.Cancel();
            return [1];
        }

        public byte[]? Get(string url) => null;
    }
}
