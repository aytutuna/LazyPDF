using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class AnnotationReadTests
{
    private const string Everything =
        "<</Type /Annot /Subtype /FreeText /Rect [300 400 100 200] /Contents (caf\\351) /T <FEFF00410079015F0065> /Subj (Subject) /NM (id-1)" +
        " /CreationDate (D:20260102030405+03'00') /M (D:20260102030405Z) /F 28 /C [1 0 0] /IC [0.5] /CA 0.5" +
        " /BS <</W 3 /S /D /D [4 2]>> /IRT 21 0 R /RT /Group /StateModel (Review) /State (Accepted)" +
        " /QuadPoints [1 2 3 4 5 6 7 8] /InkList [[1 2 3 4] [5 6]] /Vertices [1 2 3 4 5 6] /L [1 2 3 4] /LE [/Circle /ClosedArrow]" +
        " /CL [1 2 3 4] /IT /FreeTextCallout /RD [1 2 3 4] /BE <</S /C /I 2>> /DA (/Helv 12 Tf 0 g) /DS (font: Arial 12pt)" +
        " /RC (<body/>) /Q 2 /Name /Comment /Popup 22 0 R /AP <</N 23 0 R>> /Extra (unknown)>>";

    private static PdfAnnotation One(string body)
    {
        var document = Blank(1, pdf => pdf.Obj(20, body), "/Annots [20 0 R]");
        return PdfAnnotations.Read(document, document.Pages[0]).Single();
    }

    [Fact]
    public void ReadsEveryKey()
    {
        var a = One(Everything);
        Assert.Equal("FreeText", a.Subtype);
        Assert.Equal(AnnotationType.FreeText, a.Type);
        Assert.Equal(new PdfRect(100, 200, 300, 400), a.Rect);
        Assert.Equal("café", a.Contents);
        Assert.Equal("Ayşe", a.Title);
        Assert.Equal("Subject", a.Subject);
        Assert.Equal("id-1", a.Name);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.FromHours(3)), a.Created);
        Assert.Equal(new DateTimeOffset(2026, 1, 2, 3, 4, 5, TimeSpan.Zero), a.Modified);
        Assert.Equal(AnnotationFlags.Print | AnnotationFlags.NoZoom | AnnotationFlags.NoRotate, a.Flags);
        Assert.Equal([1d, 0d, 0d], a.Color);
        Assert.Equal([0.5], a.InteriorColor);
        Assert.Equal(0.5, a.Opacity);
        Assert.Equal(new AnnotationBorder(3, BorderStyle.Dashed, [4, 2]).Style, a.Border.Style);
        Assert.Equal([4d, 2d], a.Border.Dash);
        Assert.Equal(21, a.InReplyTo!.Number);
        Assert.Equal("Group", a.ReplyType);
        Assert.Equal(ReviewStatus.Accepted, a.State);
        Assert.Equal(8, a.QuadPoints.Count);
        Assert.Equal(2, a.InkList.Count);
        Assert.Equal([5d, 6d], a.InkList[1]);
        Assert.Equal(6, a.Vertices.Count);
        Assert.Equal([1d, 2d, 3d, 4d], a.Line);
        Assert.Equal((LineEnding.Circle, LineEnding.ClosedArrow), (a.StartEnding, a.EndEnding));
        Assert.Equal(4, a.Callout.Count);
        Assert.Equal("FreeTextCallout", a.Intent);
        Assert.Equal([1d, 2d, 3d, 4d], a.RectDifference);
        Assert.Equal(2, a.Cloud);
        Assert.Equal("/Helv 12 Tf 0 g", a.DefaultAppearance);
        Assert.Equal("font: Arial 12pt", a.DefaultStyle);
        Assert.Equal("<body/>", a.RichText);
        Assert.Equal(2, a.Alignment);
        Assert.Equal("Comment", a.IconName);
        Assert.Equal(22, a.Popup!.Number);
        Assert.True(a.HasAppearance);
        Assert.Equal(20, a.Reference!.Number);
        Assert.True(a.Dictionary.ContainsKey("Extra"));
    }

    [Fact]
    public void ReadsTheOlderBorderArrayAndASingleEnding()
    {
        var a = One("<</Subtype /Line /Rect [0 0 10 10] /Border [0 0 2 [3 1]] /LE /OpenArrow /L [0 0 10 10]>>");
        Assert.Equal(2, a.Border.Width);
        Assert.Equal(BorderStyle.Dashed, a.Border.Style);
        Assert.Equal([3d, 1d], a.Border.Dash);
        Assert.Equal((LineEnding.OpenArrow, LineEnding.None), (a.StartEnding, a.EndEnding));
        var plain = One("<</Subtype /Square /Rect [0 0 10 10]>>");
        Assert.Equal(new AnnotationBorder(1, BorderStyle.Solid, []).Width, plain.Border.Width);
        Assert.Null(plain.Color);
        Assert.Equal(1, plain.Opacity);
    }

    [Fact]
    public void WrongTypesFallBackToDefaults()
    {
        var a = One("<</Subtype /Highlight /Rect [1 2] /C [1 2] /CA (x) /F /name /QuadPoints (no) /BS 5 /LE 7 /IRT 3 /Contents 12 /M (junk) /State (Bogus) /Popup (x) /InkList 9>>");
        Assert.Equal(new PdfRect(0, 0, 0, 0), a.Rect);
        Assert.Null(a.Color);
        Assert.Equal(1, a.Opacity);
        Assert.Equal(AnnotationFlags.None, a.Flags);
        Assert.Empty(a.QuadPoints);
        Assert.Equal(LineEnding.None, a.StartEnding);
        Assert.Null(a.InReplyTo);
        Assert.Null(a.Contents);
        Assert.Null(a.Modified);
        Assert.Null(a.State);
        Assert.Null(a.Popup);
        Assert.Empty(a.InkList);
        Assert.False(a.HasAppearance);
    }

    [Fact]
    public void JunkInTheArrayIsSkipped()
    {
        var document = Blank(1, pdf =>
        {
            pdf.Obj(20, "<</Subtype /Text /Rect [0 0 5 5]>>");
            pdf.Obj(21, "<</Rect [0 0 5 5]>>");
            pdf.Obj(22, "[1 2]");
            pdf.Obj(23, "<</Subtype /Unheard /Rect [0 0 5 5]>>");
        }, "/Annots [null 7 20 0 R 21 0 R 22 0 R 99 0 R 23 0 R (x)]");
        var list = PdfAnnotations.Read(document, document.Pages[0]);
        Assert.Equal(["Text", "Unheard"], list.Select(a => a.Subtype));
        Assert.Equal(AnnotationType.Other, list[1].Type);
        Assert.Equal(0, list[0].PageIndex);
        Assert.False(list[1].IsMarkup);
        Assert.True(list[0].IsMarkup);
    }

    [Fact]
    public void LoopsAndHugeArraysDoNotHang()
    {
        var document = Blank(1, pdf => pdf.Obj(20, "<</Subtype /Text /Rect [0 0 5 5] /IRT 20 0 R /Popup 20 0 R>>"), "/Annots [20 0 R 20 0 R]");
        Assert.Equal(2, PdfAnnotations.Read(document, document.Pages[0]).Count);
        Assert.DoesNotContain(PdfComments.List(document), c => c.Replies.Count > 0);
    }

    [Fact]
    public void StatesAndEndingsAreReadByTheirNames()
    {
        var a = One("<</Subtype /Text /Rect [0 0 5 5] /State (2) /LE /3>>");
        Assert.Null(a.State);
        Assert.Equal(LineEnding.None, a.StartEnding);
        Assert.Null(One("<</Subtype /Text /Rect [0 0 5 5] /State ( Rejected )>>").State);
        Assert.Equal(ReviewStatus.Rejected, One("<</Subtype /Text /Rect [0 0 5 5] /State (Rejected)>>").State);
    }

    [Fact]
    public void ArraysManyAnnotationsPointToAreReadOnce()
    {
        var document = Blank(1, pdf =>
        {
            pdf.Obj(20, "<</Subtype /Highlight /Rect [0 0 5 5] /QuadPoints 21 0 R /InkList 22 0 R>>");
            pdf.Obj(21, "[" + string.Concat(Enumerable.Repeat("1 ", 100_000)) + "]");
            pdf.Obj(22, "[" + string.Concat(Enumerable.Repeat("21 0 R ", 50_000)) + "]");
        }, "/Annots [" + string.Concat(Enumerable.Repeat("20 0 R ", 20_000)) + "]");
        var list = PdfAnnotations.Read(document, document.Pages[0]);
        Assert.Equal(20_000, list.Count);
        Assert.Equal(100_000, list[^1].QuadPoints.Count);
        Assert.Equal(50_000, list[^1].InkList.Count);
        Assert.Same(list[0].QuadPoints, list[^1].QuadPoints);
    }

    [Fact]
    public void ReadAllWalksEveryPage()
    {
        var document = Blank(3);
        var writer = new PdfAnnotationWriter(document);
        writer.AddSquare(document.Pages[0], new PdfRect(1, 1, 50, 50));
        writer.AddSquare(document.Pages[2], new PdfRect(1, 1, 50, 50));
        Assert.Equal([0, 2], PdfAnnotations.ReadAll(document).Select(a => a.PageIndex));
    }

    [Fact]
    public void QuadsRoundTripAndHaveBounds()
    {
        var quad = MarkupQuad.FromRect(new PdfRect(10, 20, 110, 40));
        Assert.Equal(new PdfRect(10, 20, 110, 40), quad.Bounds);
        Assert.Equal((10, 40, 110, 20), (quad.X1, quad.Y1, quad.X4, quad.Y4));
    }

    [Fact]
    public void PermissionsAreReportedNotEnforced()
    {
        Assert.True(PdfAnnotations.CanAnnotate(Blank()));
        byte[] id = new byte[16];
        var locked = PdfSecurity.Create("user", "owner", PdfPermissions.Print | PdfPermissions.Copy, PdfCryptStrength.Aes256, id);
        byte[] file = Blank().SaveRewrite(new PdfSaveOptions(Security: locked, DocumentId: id));
        Assert.False(PdfAnnotations.CanAnnotate(PdfDocument.Open(file, "user")));
        Assert.True(PdfAnnotations.CanAnnotate(PdfDocument.Open(file, "owner")));

        var open = PdfSecurity.Create("user", "owner", PdfPermissions.Annotate, PdfCryptStrength.Aes256, id);
        Assert.True(PdfAnnotations.CanAnnotate(PdfDocument.Open(Blank().SaveRewrite(new PdfSaveOptions(Security: open, DocumentId: id)), "user")));
    }

    [Fact]
    public void AnnotatingAnEncryptedFileSavesAndReopens()
    {
        byte[] id = new byte[16];
        var security = PdfSecurity.Create("user", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, id);
        var document = PdfDocument.Open(Blank().SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id)), "user");
        var writer = new PdfAnnotationWriter(document);
        writer.AddTextMarkup(document.Pages[0], AnnotationType.Highlight, [MarkupQuad.FromRect(new PdfRect(10, 10, 100, 24))], new AnnotationInfo("A", "secret note"));
        var reopened = PdfDocument.Open(document.SaveIncremental(), "user");
        Assert.Equal("secret note", PdfAnnotations.Read(reopened, reopened.Pages[0]).Single().Contents);
    }
}
