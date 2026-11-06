using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RotatedAndEncryptedTests
{
    [Theory]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void RotatedPagesAreEditedInUserSpace(int rotate)
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET", $"/Rotate {rotate}");
        var before = EditKit.Glyphs(session);
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        Assert.True(result.Done, result.Problem);
        Assert.Contains("Hello grand world", EditKit.Text(session));
        Assert.Equal(before.Take(6), EditKit.Glyphs(session).Take(6));
    }

    [Fact]
    public void TextRotatedInTheContentIsEditedAlongItsBaseline()
    {
        var session = EditKit.Session("BT /F1 12 Tf 0 1 -1 0 300 300 Tm (Hello brave world) Tj ET");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        Assert.True(result.Done, result.Problem);
        Assert.Contains("Hello grand world", EditKit.Text(session));
        var glyphs = EditKit.Glyphs(session);
        Assert.All(glyphs, g => Assert.Equal(300, g.X, 3));
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes256)]
    [InlineData(PdfCryptStrength.Aes128)]
    public void EncryptedFilesAreEditedAndStayEncrypted(PdfCryptStrength strength)
    {
        var plain = PdfDocument.Open(EditKit.File("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET"));
        byte[] id = Enumerable.Range(1, 16).Select(i => (byte)i).ToArray();
        byte[] locked = plain.SaveRewrite(new PdfSaveOptions(Security: PdfSecurity.Create("user", "owner", PdfPermissions.All, strength, id), DocumentId: id));
        var session = PdfEditSession.Open(locked, "user");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        Assert.True(result.Done, result.Problem);
        var reopened = PdfDocument.Open(session.Current.ToArray(), "user");
        Assert.True(reopened.IsEncrypted);
        Assert.Contains("Hello grand world", TextPage.Create(reopened, reopened.Pages[0]).Text);
        Assert.DoesNotContain("grand", System.Text.Encoding.Latin1.GetString(session.Current.ToArray()));
        // The stream is deflated, so the text is never plain; what encryption changes is the deflated bytes themselves.
        foreach (var stored in StoredContents(reopened)) Assert.Equal(-1, session.Current.Span.IndexOf(stored));
        Assert.True(session.Undo());
        Assert.Contains("brave", TextPage.Create(session.Document, session.Document.Pages[0]).Text);
    }

    private static List<byte[]> StoredContents(PdfDocument document)
    {
        var contents = document.Resolve(document.Pages[0].Dictionary["Contents"]);
        var stored = (contents is PdfArray array ? array.Items : [contents!]).Select(document.Resolve).OfType<PdfStream>().Select(document.RawData).ToList();
        Assert.NotEmpty(stored);
        return stored;
    }

    [Fact]
    public void AnUnencryptedFileHoldsTheEditedStreamAsStored()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET");
        Assert.True(new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand").Done);
        var reopened = PdfDocument.Open(session.Current.ToArray());
        foreach (var stored in StoredContents(reopened)) Assert.NotEqual(-1, session.Current.Span.IndexOf(stored));
    }
}
