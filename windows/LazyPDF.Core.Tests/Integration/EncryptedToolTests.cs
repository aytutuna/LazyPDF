using Xunit;

namespace LazyPDF.Core.Tests;

public class EncryptedToolTests
{
    private const string User = IntegrationFiles.Password;

    private static byte[] Locked(PdfCryptStrength strength) => IntegrationFiles.Encrypt(IntegrationFiles.Form(2), strength);

    private static string Text(byte[] bytes, string? password, int page = 0)
    {
        var document = PdfDocument.Open(bytes, password);
        return TextPage.Create(document, document.Pages[page]).Text;
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void Redact(PdfCryptStrength strength)
    {
        using var document = PdfDocument.Open(Locked(strength), "owner");
        var result = new PdfRedactor(document, new ArialSource()).Apply([RedactionKit.MarkOf(document, 0, "body")]);
        Assert.True(result.Verification.IsClean, string.Join("; ", result.Verification.Problems));
        Assert.True(PdfDocument.Open(result.Bytes, User).IsEncrypted);
        Assert.DoesNotContain("body", Text(result.Bytes, User));
        Assert.Contains("Page 1", Text(result.Bytes, User));
        IntegrationFiles.ReadBack(result.Bytes, User);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void OptimizeComesOutOpenUnlessAHandlerIsGiven(PdfCryptStrength strength)
    {
        using var document = PdfDocument.Open(Locked(strength), User);
        var open = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Small));
        Assert.False(PdfDocument.Open(open.Bytes).IsEncrypted);
        Assert.Contains("Page 2 body", Text(open.Bytes, null, 1));

        var locked = new PdfOptimizer(document).Run(OptimizeOptions.For(OptimizePreset.Small) with { Security = IntegrationFiles.Secure(strength), DocumentId = IntegrationFiles.FileId });
        Assert.True(PdfDocument.Open(locked.Bytes, User).IsEncrypted);
        Assert.Contains("Page 2 body", Text(locked.Bytes, User, 1));
        IntegrationFiles.ReadBack(locked.Bytes, User);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void Sanitize(PdfCryptStrength strength)
    {
        using var document = PdfDocument.Open(Locked(strength), User);
        var cleaned = new PdfSanitizer(document).Run(new SanitizeOptions { Security = IntegrationFiles.Secure(strength), DocumentId = IntegrationFiles.FileId });
        Assert.True(PdfDocument.Open(cleaned.Bytes, User).IsEncrypted);
        Assert.Contains("Page 1 body", Text(cleaned.Bytes, User));
        IntegrationFiles.ReadBack(cleaned.Bytes, User);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void LinearizeComesOutOpenUnlessAHandlerIsGiven(PdfCryptStrength strength)
    {
        using var document = PdfDocument.Open(Locked(strength), "owner");
        var open = document.SaveLinearized();
        Assert.True(PdfDocument.Open(open).IsLinearized);
        Assert.False(PdfDocument.Open(open).IsEncrypted);

        byte[] linear = document.SaveLinearized(new PdfSaveOptions(Security: IntegrationFiles.Secure(strength), DocumentId: IntegrationFiles.FileId));
        var again = PdfDocument.Open(linear, User);
        Assert.True(again.IsLinearized);
        Assert.True(again.IsEncrypted);
        Assert.Contains("Page 2 body", Text(linear, User, 1));
        IntegrationFiles.ReadBack(linear, User);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void ConvertToPdfA(PdfCryptStrength strength)
    {
        var converted = new PdfAConverter(new SystemFonts()).Convert(Locked(strength), PdfALevel.A2b, StandardsKit.Date, "owner");
        Assert.True(converted.IsClean, string.Join("; ", converted.Remaining.Select(i => $"{i.Clause} {i.Where}: {i.Message}")));
        Assert.False(PdfDocument.Open(converted.Bytes!).IsEncrypted);
        Assert.Contains("Page 1 body", Text(converted.Bytes!, null));

        Assert.NotNull(new PdfAConverter().Convert(Locked(strength), PdfALevel.A2b, StandardsKit.Date, "wrong").Refusal);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void Tag(PdfCryptStrength strength)
    {
        var session = PdfEditSession.Open(Locked(strength), User);
        Assert.False(AutoTagger.Tag(session.Document).AlreadyTagged);
        Assert.True(session.Commit("Tag"));
        var again = IntegrationFiles.Reopen(session, User);
        Assert.Contains("Page 1 body text", ReadingOrder.Export(again));
        Assert.True(session.Undo());
        Assert.Null(StructureTree.Read(IntegrationFiles.Reopen(session, User)));
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public async Task Ocr(PdfCryptStrength strength)
    {
        var session = PdfEditSession.Open(IntegrationFiles.Encrypt(OcrKit.ScanBytes(1), strength), User);
        var result = await PdfSearchable.RunAsync(session, new FakeRecognizer(OcrKit.Words(dpi: 144)), new FakeRenderer(session.Document), new OcrOptions(Dpi: 144));
        Assert.True(result.Committed);
        var again = IntegrationFiles.Reopen(session, User);
        Assert.True(again.IsEncrypted);
        Assert.True(PdfOcrLayer.Has(again, again.Pages[0]));
        OcrKit.AssertAtBoxes(again);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void CompareAndExportReadTheSameText(PdfCryptStrength strength)
    {
        byte[] plain = IntegrationFiles.Form(2);
        var result = PdfComparer.Compare(PdfDocument.Open(plain), PdfDocument.Open(Locked(strength), User));
        Assert.True(result.IsIdentical);

        string text = PlainTextWriter.Make(ExportLayout.Analyze(PdfDocument.Open(Locked(strength), User)));
        Assert.Contains("Page 2 body text", text);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void Sign(PdfCryptStrength strength)
    {
        byte[] signed = PdfSigner.Sign(Locked(strength), SignatureKit.Request(Pki.Instance), User);
        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, new VerifyOptions { TrustAnchors = [Pki.Instance.Root], Password = User }));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.True(PdfDocument.Open(signed, User).IsEncrypted);
        IntegrationFiles.ReadBack(signed, User);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void EditText(PdfCryptStrength strength)
    {
        var session = PdfEditSession.Open(Locked(strength), User);
        var hit = TextSearch.Find(TextPage.Create(session.Document, session.Document.Pages[0]), "body").First();
        var edit = new PageEditor(session, 0).ReplaceText(hit.Range, "text");
        Assert.True(edit.Done, edit.Problem);
        Assert.Contains("Page 1 text text", Text(session.Current.ToArray(), User));
    }
}
