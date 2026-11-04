using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SessionSeamTests
{
    [Fact]
    public void DuplicatedPageGetsItsOwnFields()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(2));
        PageOperations.Duplicate(document, [0]);
        var form = PdfForm.Read(document);
        Assert.Equal(3, document.Pages.Count);
        Assert.NotNull(form.Find("f1_2"));

        form.SetValues(new Dictionary<string, string?> { ["f1"] = "original", ["f1_2"] = "copy" });
        var bytes = document.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);
        var again = PdfForm.Read(PdfDocument.Open(bytes));
        Assert.Equal("original", again.Find("f1")!.Value);
        Assert.Equal("copy", again.Find("f1_2")!.Value);
        Assert.Equal(0, again.Find("f1")!.Widgets[0].PageIndex);
        Assert.Equal(1, again.Find("f1_2")!.Widgets[0].PageIndex);
    }

    [Fact]
    public void ResizedPageStillFillsAndFlattens()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(1));
        PageOperations.Resize(document, [0], 800, 1200, ResizeMode.ScaleContent);
        var form = PdfForm.Read(document);
        var rect = form.Find("f1")!.Widgets[0].Rect;
        Assert.Equal(80, rect.Left, 3);
        Assert.Equal(480, rect.Right, 3);

        form.SetValue("f1", "after resize");
        form.Flatten();
        Assert.Contains("after resize", IntegrationFiles.ReadBack(document.SaveRewrite())[0]);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void CommitsOnlyAppendToTheOriginalBytes(bool encrypted)
    {
        var plain = IntegrationFiles.Form(3, bookmarks: [0, 1]);
        var original = encrypted ? IntegrationFiles.Encrypt(plain, PdfCryptStrength.Aes256) : plain;
        var password = encrypted ? IntegrationFiles.Password : null;
        var session = PdfEditSession.Open(original, password);

        PdfForm.Read(session.Document).SetValue("f1", "signed off");
        Assert.True(session.Commit("fill"));
        PageOperations.Rotate(session.Document, [0], 90);
        Assert.True(session.Commit("rotate"));
        new PdfStamper(session.Document).AddWatermark(new WatermarkSpec { Text = "DRAFT" });
        Assert.True(session.Commit("stamp"));
        PageOperations.Delete(session.Document, [2]);
        Assert.True(session.Commit("delete"));

        Assert.True(session.Current.Span[..original.Length].SequenceEqual(original));
        Assert.True(session.Current.Length > original.Length);
        Assert.Equal(2, IntegrationFiles.Reopen(session, password).Pages.Count);
    }

    [Fact]
    public void UndoingADeleteBringsBackPageFieldAndBookmark()
    {
        var session = PdfEditSession.Open(IntegrationFiles.Form(3, bookmarks: [0, 1, 2]));
        PageOperations.Delete(session.Document, [1]);
        Assert.True(session.Commit("delete"));
        var after = IntegrationFiles.Reopen(session);
        Assert.Equal(2, after.Pages.Count);
        Assert.Null(PdfForm.Read(after).Find("f2"));

        Assert.True(session.Undo());
        var back = IntegrationFiles.Reopen(session);
        Assert.Equal(3, back.Pages.Count);
        Assert.NotNull(PdfForm.Read(back).Find("f2"));
        Assert.Equal(1, Outline.Read(back).Items[1].Destination!.PageIndex);
    }

    [Fact]
    public void AnnotationsOnACroppedRotatedPageLandWhereTheyAreDrawn()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(1, pageExtra: "/Rotate 90 /CropBox [100 100 300 500]"));
        var page = document.Pages[0];
        var geometry = new PageGeometry(page);
        var shown = new DisplayRect(20, 30, 100, 40);
        var user = geometry.ToUser(shown);
        var note = new PdfAnnotationWriter(document).AddFreeText(page, user, "placed");

        var again = PdfDocument.Open(document.SaveRewrite());
        var read = PdfAnnotations.Read(again, again.Pages[0]).Single(a => a.Type == AnnotationType.FreeText);
        var back = geometry.ToDisplay(read.Rect);
        Assert.Equal(shown.X, back.X, 3);
        Assert.Equal(shown.Y, back.Y, 3);
        Assert.Equal(shown.Width, back.Width, 3);
        Assert.Equal(note.Rect, read.Rect);
    }
}
