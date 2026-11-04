using System.Security.Cryptography.X509Certificates;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Signing with what the panel collects, through the real signer and verifier.
public sealed class CertificateSigningTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 10, 9, 0, 0, TimeSpan.Zero);

    private sealed class NoServer : ISignatureTransport
    {
        public byte[]? Post(string url, string contentType, byte[] body) => null;

        public byte[]? Get(string url) => null;
    }

    private static X509Certificate2 Ada() => PdfDigitalId.Create("Ada Lovelace", null, Now.AddDays(-1), years: 2, keyBits: 2048);

    private static SignChoices Plain(X509Certificate2 certificate) =>
        new(certificate, null, 0, null, "", "", CertificationLevel.None, null, false);

    private static PdfSignRequest Request(SignChoices choices) => CertificateSigning.Request(choices, new NoServer(), new FakeFonts(), Now);

    private static SignatureReport Only(PdfEditSession session, SigningSettings? settings = null) =>
        Assert.Single(PdfSignatureVerifier.Verify(session.Current.ToArray(), (settings ?? new SigningSettings { TrustWindowsStore = false }).Verify(null, null, Now)));

    [Fact]
    public void AnInvisibleSignatureIsMadeByTheCertificate()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());

        PdfSigner.Sign(session, Request(Plain(ada)));

        var report = Only(session);
        Assert.Equal("Ada Lovelace", report.SignerName);
        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.True(session.CanUndo);
    }

    [Fact]
    public void AddingTheCertificateToTheTrustedOnesMakesItValid()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());
        PdfSigner.Sign(session, Request(Plain(ada)));
        var settings = new SigningSettings { TrustWindowsStore = false, TrustedCertificates = [Convert.ToBase64String(ada.RawData)] };

        Assert.Equal(SignatureVerdict.Valid, Only(session, settings).Verdict);
    }

    [Fact]
    public void ReasonAndPlaceAreSignedAndBlankOnesLeftOut()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());
        PdfSigner.Sign(session, Request(Plain(ada) with { Reason = "  Approved ", Location = "   " }));

        var report = Only(session);

        Assert.Equal("Approved", report.Reason);
        Assert.Null(report.Location);
    }

    [Fact]
    public void ABoxMakesAVisibleSignatureOnThatPage()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text(2));
        var box = new PdfRect(72, 600, 272, 660);

        PdfSigner.Sign(session, Request(Plain(ada) with { Page = 1, Rect = box }));

        var widget = Assert.Single(PdfAnnotations.ReadAll(session.Document), a => a.Type == AnnotationType.Widget);
        Assert.Equal(1, widget.PageIndex);
        Assert.Equal(box, widget.Rect);
        Assert.Equal(SignatureVerdict.ValidButUntrusted, Only(session).Verdict);
    }

    [Fact]
    public void AnEmptyFieldOfTheFileIsSignedWhereItStands()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());
        PdfForm.Read(session.Document).AddField(new FieldSpec(FieldKind.Signature, "Approval", 0, new PdfRect(72, 100, 200, 150)));
        session.Commit("Field");
        Assert.Equal(["Approval"], CertificateSigning.EmptyFields(session.Document));

        PdfSigner.Sign(session, Request(Plain(ada) with { Field = "Approval" }));

        Assert.Equal("Approval", Only(session).FieldName);
        Assert.Empty(CertificateSigning.EmptyFields(session.Document));
    }

    [Fact]
    public void TheFirstSignatureCanCertifyTheFile()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());

        PdfSigner.Sign(session, Request(Plain(ada) with { Certify = CertificationLevel.FormFill }));

        var report = Only(session);
        Assert.Equal(SignatureKind.Certification, report.Kind);
        Assert.Equal(CertificationLevel.FormFill, report.Certification);
    }

    [Fact]
    public void ASecondSignatureCannotCertify()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());
        PdfSigner.Sign(session, Request(Plain(ada)));

        var error = Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(session, Request(Plain(ada) with { Certify = CertificationLevel.NoChanges })));

        Assert.Equal(SignatureText.NotCertifiable, error.Message);
    }

    [Fact]
    public void AddressAndLongTermChooseTheLevel()
    {
        using var ada = Ada();
        var none = Request(Plain(ada));
        var stamped = Request(Plain(ada) with { TimestampUrl = "http://tsa.example/stamp" });
        var longTerm = Request(Plain(ada) with { TimestampUrl = "http://tsa.example/stamp", LongTerm = true });
        var blank = Request(Plain(ada) with { TimestampUrl = "", LongTerm = true });

        Assert.Equal(PadesLevel.B, none.Level);
        Assert.Null(none.Timestamp);
        Assert.Equal(PadesLevel.T, stamped.Level);
        Assert.Equal("http://tsa.example/stamp", stamped.Timestamp!.Url);
        Assert.Equal(PadesLevel.LT, longTerm.Level);
        Assert.Equal(PadesLevel.B, blank.Level);
    }

    [Fact]
    public void ATimeStampServerThatAnswersNothingIsSaidSo()
    {
        using var ada = Ada();
        var session = PdfEditSession.Open(Pdfs.Text());

        var error = Assert.ThrowsAny<InvalidOperationException>(() =>
            PdfSigner.Sign(session, Request(Plain(ada) with { TimestampUrl = "http://tsa.example/stamp" })));

        Assert.Equal(SignatureText.NoTimestamp, error.Message);
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void ACertificateWithoutItsKeyIsRefused()
    {
        using var ada = Ada();
        using var publicOnly = X509CertificateLoader.LoadCertificate(ada.RawData);
        var session = PdfEditSession.Open(Pdfs.Text());

        var error = Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(session, Request(Plain(publicOnly))));

        Assert.Equal(SignatureText.NoPrivateKey, error.Message);
    }

    [Fact]
    public async Task CancelStopsTheNextRequestToAServer()
    {
        using var cancel = new CancellationTokenSource();
        var transport = new CancellableTransport(new NoServer(), cancel.Token);
        Assert.Null(transport.Get("http://x"));

        await cancel.CancelAsync();

        Assert.Throws<OperationCanceledException>(() => transport.Post("http://x", "a/b", []));
        Assert.Throws<OperationCanceledException>(() => transport.Get("http://x"));
    }

    [Fact]
    public void AFileWithoutSignaturesTakesNoValidationData()
    {
        var session = PdfEditSession.Open(Pdfs.Text());

        Assert.Throws<InvalidOperationException>(() => PdfLongTermValidation.Add(session, new NoServer(), Now));
    }
}
