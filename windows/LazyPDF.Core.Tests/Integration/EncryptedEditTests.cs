using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class EncryptedEditTests
{
    private static byte[] Make(string kind) => kind switch
    {
        "aes128" => IntegrationFiles.Encrypt(IntegrationFiles.Form(4, bookmarks: [0, 2]), PdfCryptStrength.Aes128),
        "aes128-objects" => IntegrationFiles.Encrypt(IntegrationFiles.Form(4, bookmarks: [0, 2]), PdfCryptStrength.Aes128, true),
        "aes256" => IntegrationFiles.Encrypt(IntegrationFiles.Form(4, bookmarks: [0, 2]), PdfCryptStrength.Aes256),
        "aes256-objects" => IntegrationFiles.Encrypt(IntegrationFiles.Form(4, bookmarks: [0, 2]), PdfCryptStrength.Aes256, true),
        _ => throw new ArgumentException(kind),
    };

    [Theory]
    [InlineData("aes128")]
    [InlineData("aes128-objects")]
    [InlineData("aes256")]
    [InlineData("aes256-objects")]
    public void EveryEditCommitsUndoesAndRedoesOnAnEncryptedFile(string kind)
    {
        var password = IntegrationFiles.Password;
        var session = PdfEditSession.Open(Make(kind), password);
        Assert.True(session.Document.IsEncrypted);
        var steps = new List<(string Label, Action<PdfDocument> Edit, int Pages)>
        {
            ("annotate", d =>
            {
                var writer = new PdfAnnotationWriter(d);
                var info = new AnnotationInfo("me", "note", Date: new DateTimeOffset(2026, 5, 5, 0, 0, 0, TimeSpan.Zero));
                writer.AddTextMarkup(d.Pages[0], AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(40, 495, 200, 515))], info);
                writer.AddFreeText(d.Pages[0], new PdfRect(40, 300, 300, 340), "encrypted free text", info: info);
                writer.AddStamp(d.Pages[1], new PdfRect(40, 200, 200, 260), "Approved", info);
            }, 4),
            ("fill", d => PdfForm.Read(d).SetValues(new Dictionary<string, string?> { ["f1"] = "secret value", ["agree"] = "Yes" }), 4),
            ("stamp", d =>
            {
                var stamper = new PdfStamper(d);
                stamper.AddWatermark(new WatermarkSpec { Text = "WATERMARK", LayerName = "Mark" });
                stamper.AddHeaderFooter(new HeaderFooterSpec { Footer = new HeaderFooterBand(Center: "{page}/{pages}") });
            }, 4),
            ("rotate", d => PageOperations.Rotate(d, [1, 2], 90), 4),
            ("outline", d =>
            {
                var outline = Outline.Read(d);
                outline.Items[0].Title = "Renamed";
                outline.Write(d);
                (DocumentMetadata.Read(d) with { Title = "Locked title" }).Write(d);
            }, 4),
            ("import", d => PageOperations.ImportPages(d, PdfDocument.Open(IntegrationFiles.Form(2, prefix: "x")), [0, 1], 4), 6),
            ("delete", d => PageOperations.Delete(d, [0]), 5),
            ("flatten", d =>
            {
                PdfForm.Read(d).Flatten();
                PdfAnnotationFlattener.FlattenAll(d);
            }, 5),
        };

        var counts = new List<int> { 4 };
        foreach (var (label, edit, pages) in steps)
        {
            edit(session.Document);
            Assert.True(session.Commit(label), label);
            var document = IntegrationFiles.Reopen(session, password);
            Assert.Equal(pages, document.Pages.Count);
            Assert.True(document.IsEncrypted);
            counts.Add(pages);
        }

        var final = IntegrationFiles.ReadBack(session.Current.ToArray(), password);
        Assert.Contains("APPROVED", final[0] + final[1]);
        Assert.Contains("WATERMARK", final[0]);
        Assert.Equal("Locked title", DocumentMetadata.Read(PdfDocument.Open(session.Current.ToArray(), password)).Title);

        // The committed bytes never hold the plain strings.
        var raw = System.Text.Encoding.Latin1.GetString(session.Current.Span);
        Assert.DoesNotContain("secret value", raw);
        Assert.DoesNotContain("Locked title", raw);

        for (int i = counts.Count - 2; i >= 0; i--)
        {
            Assert.True(session.Undo());
            Assert.Equal(counts[i], IntegrationFiles.Reopen(session, password).Pages.Count);
        }
        Assert.False(session.CanUndo);
        for (int i = 1; i < counts.Count; i++)
        {
            Assert.True(session.Redo());
            Assert.Equal(counts[i], IntegrationFiles.Reopen(session, password).Pages.Count);
        }

        var path = Path.Combine(Path.GetTempPath(), $"lazypdf-{Guid.NewGuid():N}.pdf");
        try
        {
            session.SaveCompact(path);
            var saved = File.ReadAllBytes(path);
            Assert.Equal(counts[^1], PdfDocument.Open(saved, password).Pages.Count);
            IntegrationFiles.ReadBack(saved, password);
            Assert.Throws<PdfReadException>(() => PdfDocument.Open(saved, "wrong"));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ExtractSplitAndMergeOfAnEncryptedSourceWriteReadableFiles()
    {
        var source = PdfDocument.Open(Make("aes256"), IntegrationFiles.Password);
        PdfForm.Read(source).SetValue("f2", "kept");

        var part = PageAssembly.Extract(source, [1, 3]);
        var plain = part.SaveRewrite();
        Assert.False(PdfDocument.Open(plain).IsEncrypted);
        Assert.Contains("Page 2", IntegrationFiles.ReadBack(plain)[0]);

        var target = PdfDocument.Open(Make("aes128"), IntegrationFiles.Password);
        PageOperations.ImportPages(target, source, [1], 0);
        var bytes = target.SaveRewrite(new PdfSaveOptions(Security: IntegrationFiles.Secure(PdfCryptStrength.Aes256)));
        var texts = IntegrationFiles.ReadBack(bytes, IntegrationFiles.Password);
        Assert.Equal(5, texts.Count);
        Assert.Contains("Page 2", texts[0]);
        Assert.Equal("kept", PdfForm.Read(PdfDocument.Open(bytes, IntegrationFiles.Password)).Find("f2_2")!.Value);
    }

    [Theory]
    [InlineData("crypt-rc4-40.pdf", "secret")]
    [InlineData("crypt-aes128.pdf", "secret")]
    [InlineData("crypt-aes256-r5.pdf", "secret")]
    [InlineData("crypt-aes256.pdf", "secret")]
    [InlineData("crypt-aes256.pdf", "owner")]
    [InlineData("owner-only-rc4.pdf", null)]
    [InlineData("owner-only-aes.pdf", null)]
    public void ForeignEncryptedFilesTakeEditsAndUndo(string name, string? password)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "Documents", name);
        Assert.True(File.Exists(path), "fixture missing: " + name);
        var session = PdfEditSession.Open(File.ReadAllBytes(path), password);
        var count = session.Document.Pages.Count;

        new PdfAnnotationWriter(session.Document).AddSquare(session.Document.Pages[0], new PdfRect(10, 10, 60, 60));
        Assert.True(session.Commit("square"));
        new PdfStamper(session.Document).AddWatermark(new WatermarkSpec { Text = "COPY" });
        Assert.True(session.Commit("stamp"));
        (DocumentMetadata.Read(session.Document) with { Title = "Edited" }).Write(session.Document);
        Assert.True(session.Commit("title"));

        var document = IntegrationFiles.Reopen(session, password);
        Assert.True(document.IsEncrypted);
        Assert.Equal(count, document.Pages.Count);
        Assert.Contains(PdfAnnotations.Read(document, document.Pages[0]), a => a.Type == AnnotationType.Square);
        Assert.Equal("Edited", DocumentMetadata.Read(document).Title);

        Assert.True(session.Undo());
        Assert.True(session.Undo());
        var undone = IntegrationFiles.Reopen(session, password);
        Assert.NotEqual("Edited", DocumentMetadata.Read(undone).Title);
        Assert.Contains(PdfAnnotations.Read(undone, undone.Pages[0]), a => a.Type == AnnotationType.Square);
    }
}
