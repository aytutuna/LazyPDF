using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureSeamTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static RedactionResult Redact(byte[] file, string word, string? password = null)
    {
        using var document = PdfDocument.Open(file, password);
        return new PdfRedactor(document, new ArialSource()).Apply([RedactionKit.MarkOf(document, 0, word)]);
    }

    [Fact]
    public void RedactedFileIsSignedAndTheTextStaysGone()
    {
        var redacted = Redact(SignatureKit.Plain(1), "Contract");
        Assert.True(redacted.Verification.IsClean);

        byte[] signed = PdfSigner.Sign(redacted.Bytes, SignatureKit.Request(Pki));
        var report = Assert.Single(SignatureKit.Verify(signed));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.True(report.CoversWholeFile);

        Assert.False(RedactionKit.Holds(signed, "Contract"));
        using var pig = UglyToad.PdfPig.PdfDocument.Open(signed);
        Assert.DoesNotContain("Contract", pig.GetPage(1).Text);
    }

    [Fact]
    public void FillingAfterACertifyingSignatureIsAnAllowedChange()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.FormFill);
        var session = PdfEditSession.Open(signed);
        PdfForm.Read(session.Document).SetValue("Name", "Ada Lovelace");
        Assert.True(session.Commit("Fill"));

        var report = Assert.Single(PdfSignatureVerifier.Verify(session, Pki.Trusting));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.False(report.CoversWholeFile);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill && c.Allowed);
        Assert.DoesNotContain(report.Changes.Changes, c => !c.Allowed);

        // The signed bytes are still the start of the file, and undo goes back to them.
        Assert.True(session.Current.Span[..signed.Length].SequenceEqual(signed));
        Assert.True(session.Undo());
        Assert.True(session.Current.Span.SequenceEqual(signed));
        Assert.True(Assert.Single(PdfSignatureVerifier.Verify(session, Pki.Trusting)).CoversWholeFile);
    }

    [Fact]
    public void FillingAfterAnApprovalSignatureIsAChange()
    {
        byte[] signed = PdfSigner.Sign(SignatureChangeTests.FormFile(), SignatureKit.Request(Pki));
        var session = PdfEditSession.Open(signed);
        PdfForm.Read(session.Document).SetValue("Name", "Ada Lovelace");
        session.Commit("Fill");

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Assert.Single(PdfSignatureVerifier.Verify(session, Pki.Trusting)).Verdict);
    }

    [Fact]
    public void RedactingASignedFileDropsTheSignatureAndSaysSo()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(1), SignatureKit.Request(Pki));
        Assert.True(PdfDocument.Open(signed).IsSigned);

        var result = Redact(signed, "Contract");
        Assert.True(result.Report.SignaturesRemoved > 0);
        Assert.Contains("signature", result.Report.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.False(PdfDocument.Open(result.Bytes).IsSigned);
        Assert.Empty(SignatureKit.Verify(result.Bytes));
        Assert.False(RedactionKit.Holds(result.Bytes, "Contract"));
    }

    [Fact]
    public void OptimisingASignedFileLeavesNoValidSignature()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(2), SignatureKit.Request(Pki));
        using var document = PdfDocument.Open(signed);
        Assert.True(document.IsSigned);

        var optimized = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Balanced));
        Assert.DoesNotContain(SignatureKit.Verify(optimized.Bytes), r => r.Verdict == SignatureVerdict.Valid);
    }

    [Fact]
    public void SanitisingASignedFileLeavesNoValidSignature()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(2), SignatureKit.Request(Pki));
        using var document = PdfDocument.Open(signed);
        var cleaned = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.DoesNotContain(SignatureKit.Verify(cleaned.Bytes), r => r.Verdict == SignatureVerdict.Valid);
    }

    [Fact]
    public void LinearizingASignedFileDoesNotKeepItValid()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(2), SignatureKit.Request(Pki));
        byte[] lin = PdfDocument.Open(signed).SaveLinearized();
        IntegrationFiles.ReadBack(lin);
        Assert.DoesNotContain(SignatureKit.Verify(lin), r => r.Verdict == SignatureVerdict.Valid);
    }
}
