using System.Windows;
using LazyPDF.App.Panels.Signatures;
using LazyPDF.App.Tools.Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The Signatures panel in plain words, and the signed version of a file taken out of its history.
public sealed class SignatureRowTests
{
    private static readonly DateTimeOffset Now = new(2026, 3, 10, 9, 0, 0, TimeSpan.Zero);

    private static (byte[] File, SignatureReport Report) Signed(bool comment, bool trusted = false)
    {
        using var ada = PdfDigitalId.Create("Ada Lovelace", null, Now.AddDays(-1), years: 1, keyBits: 2048);
        var session = PdfEditSession.Open(Pdfs.Text());
        PdfSigner.Sign(session, new PdfSignRequest(ada, Now) { Reason = "Approved", Fonts = new FakeFonts() });
        if (comment)
        {
            new PdfAnnotationWriter(session.Document).AddNote(session.Document.Pages[0], new PdfRect(10, 10, 30, 30), new AnnotationInfo(Contents: "hi"));
            session.Commit("Comment");
        }
        var settings = new SigningSettings { TrustWindowsStore = false, TrustedCertificates = trusted ? [Convert.ToBase64String(ada.RawData)] : [] };
        byte[] file = session.Current.ToArray();
        return (file, Assert.Single(PdfSignatureVerifier.Verify(file, settings.Verify(null, null, Now))));
    }

    private static string AllLines(SignatureRow row) => string.Join("\n", row.Sections.SelectMany(s => s.Lines));

    [Fact]
    public void AnUntouchedSignatureSaysWhoAndWhatItDidNotCheck()
    {
        var (_, report) = Signed(comment: false);

        var row = new SignatureRow(report, 0, Rect.Empty);

        Assert.Equal("Ada Lovelace", row.Title);
        Assert.Equal("Signer is not trusted", row.Status);
        Assert.Contains("Signed by Ada Lovelace on 10 Mar 2026.", row.Sentence);
        Assert.Equal(SignatureLevel.Caution, row.Level);
        Assert.Contains("Reason: Approved", AllLines(row));
        Assert.Contains("Not checked", row.Sections.Select(s => s.Heading));
        Assert.DoesNotContain("Changed since signing", row.Sections.Select(s => s.Heading));
        Assert.False(row.HasLaterRevisions);
    }

    [Fact]
    public void ATrustedSignerIsGoodAndHasNoProblems()
    {
        var (_, report) = Signed(comment: false, trusted: true);

        var row = new SignatureRow(report, 0, Rect.Empty);

        Assert.Equal(SignatureLevel.Good, row.Level);
        Assert.DoesNotContain("Problems", row.Sections.Select(s => s.Heading));
    }

    [Fact]
    public void AGoodSignatureSaysWhenSomethingWasNotChecked()
    {
        var (_, report) = Signed(comment: false, trusted: true);

        Assert.NotEmpty(new SignatureRow(report with { RevocationChecked = false }, 0, Rect.Empty).Caveat);
        Assert.Empty(new SignatureRow(report with { RevocationChecked = true, TimestampTime = Now }, 0, Rect.Empty).Caveat);
    }

    [Fact]
    public void ALaterCommentIsListedAsAChangeSinceSigning()
    {
        var (_, report) = Signed(comment: true);

        var row = new SignatureRow(report, 0, Rect.Empty);

        Assert.True(row.HasLaterRevisions);
        var changes = Assert.Single(row.Sections, s => s.Heading == "Changed since signing");
        Assert.All(changes.Lines, line => Assert.Contains("not allowed", line));
        Assert.Equal(changes.Lines.Count, changes.Lines.Distinct().Count());
        Assert.Equal(SignatureLevel.Bad, row.Level);
    }

    [Fact]
    public void TheSignedVersionIsTheFileAsItWasWhenSigned()
    {
        var (file, report) = Signed(comment: true);

        var signed = SignedVersion.Of(file, report)!;

        Assert.True(signed.Length < file.Length);
        Assert.DoesNotContain(PdfAnnotations.ReadAll(PdfDocument.Open(signed)), a => a.Type == AnnotationType.Text);
        var again = Assert.Single(PdfSignatureVerifier.Verify(signed, new SigningSettings { TrustWindowsStore = false }.Verify(null, null, Now)));
        Assert.True(again.CoversWholeFile);
        Assert.Equal(SignatureVerdict.ValidButUntrusted, again.Verdict);
    }

    [Fact]
    public void ARevisionThatIsNotThereGivesNothing()
    {
        var (file, _) = Signed(comment: false);

        Assert.Null(SignedVersion.Of(file, new SignatureReport { Revision = 9 }));
    }

    private static SignatureReport Report(SignatureVerdict verdict, params SignatureProblem[] problems) =>
        new() { Verdict = verdict, Problems = problems, SignerName = "Ada Lovelace", Revision = 2, CoversWholeFile = true };

    private static VerifyOptions Untrusting => new SigningSettings { TrustWindowsStore = false }.Verify(null, null, Now);

    [Fact]
    public void ARevokedCertificateIsBadAndSaysSo()
    {
        var row = new SignatureRow(Report(SignatureVerdict.ValidButUntrusted, SignatureProblem.UntrustedSigner, SignatureProblem.CertificateRevoked), 0, Rect.Empty);

        Assert.Equal(SignatureLevel.Bad, row.Level);
        Assert.Equal("Certificate was revoked", row.Status);
        Assert.Contains("Do not rely on this signature.", row.Sentence);
    }

    [Fact]
    public void AnotherFlawOfATrustedSignerIsNamedNotCalledUntrusted()
    {
        var row = new SignatureRow(Report(SignatureVerdict.ValidButUntrusted, SignatureProblem.WeakDigest), 0, Rect.Empty);

        Assert.Equal(SignatureLevel.Caution, row.Level);
        Assert.Equal("Signature uses a weak digest", row.Status);
    }

    [Fact]
    public void AnUnknownSignerStaysUnknown()
    {
        var row = new SignatureRow(Report(SignatureVerdict.ValidButUntrusted, SignatureProblem.UntrustedSigner), 0, Rect.Empty);

        Assert.Equal("Signer is not trusted", row.Status);
    }

    [Fact]
    public void OnlyTheCertifyingSignatureSaysItCertified()
    {
        var approval = Report(SignatureVerdict.Valid) with { Kind = SignatureKind.Approval, Certification = CertificationLevel.FormFill };
        var certifying = approval with { Kind = SignatureKind.Certification };

        Assert.DoesNotContain("Certified", AllLines(new SignatureRow(approval, 0, Rect.Empty)));
        Assert.Contains("Certified: form filling is allowed.", AllLines(new SignatureRow(certifying, 0, Rect.Empty)));
    }

    [Fact]
    public void ATailAfterTheSignatureLeavesTheSignedVersionToOpen()
    {
        var (file, _) = Signed(comment: false);
        byte[] tail = [.. file, .. "\n% added\n"u8.ToArray()];
        var report = Assert.Single(PdfSignatureVerifier.Verify(tail, Untrusting));

        var row = new SignatureRow(report, 0, Rect.Empty);

        Assert.True(row.HasLaterRevisions);
        Assert.NotNull(SignedVersion.Of(tail, report));
    }

    [Fact]
    public void ASignatureThatClosesTheFileHasNoLaterVersion()
    {
        var (_, report) = Signed(comment: false);

        Assert.False(new SignatureRow(report, 0, Rect.Empty).HasLaterRevisions);
    }

    [Fact]
    public void AFieldIsFoundByItsFullNameAndItsFirstWidget()
    {
        using var ada = PdfDigitalId.Create("Ada Lovelace", null, Now.AddDays(-1), years: 1, keyBits: 2048);
        var session = PdfEditSession.Open(Pdfs.Text(2));
        PdfForm.Read(session.Document).AddField(new FieldSpec(FieldKind.Signature, "Approval", 1, new PdfRect(72, 100, 200, 150)));
        session.Commit("Field");
        PdfSigner.Sign(session, new PdfSignRequest(ada, Now) { FieldName = "Approval", Fonts = new FakeFonts() });

        var fields = SignatureFields.Locate(session.Current.ToArray(), null, null);

        var at = Assert.Single(fields);
        Assert.Equal("Approval", at.Key);
        Assert.Equal(1, at.Value.Page);
        Assert.Equal(new PdfRect(72, 100, 200, 150), at.Value.Rect);
    }

    [Fact]
    public void ASignatureThatALaterUpdateUnhookedIsStillFound()
    {
        var (file, _) = Signed(comment: false);
        var session = PdfEditSession.Open(file);
        session.Document.Catalog.Remove("AcroForm");
        session.Commit("Strip");

        var reports = PdfSignatureVerifier.Verify(session.Current.ToArray(), Untrusting);

        Assert.Single(reports);
        Assert.False(session.Document.IsSigned);
    }
}
