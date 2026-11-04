using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// How the page's own streams are rewritten: one by one, merged only when an edit spans the break between two.
public class ContentStreamTests
{
    private static PdfEditSession Split(params string[] streams)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        var refs = string.Join(" ", streams.Select((_, i) => $"{10 + i} 0 R"));
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents [{refs}] /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(5, EditKit.Helvetica);
        for (int i = 0; i < streams.Length; i++) pdf.Stream(10 + i, i == 1 ? "/LazyPDF <</Id 1>>" : "", streams[i]);
        return PdfEditSession.Open(pdf.Finish());
    }

    private static List<int> Numbers(PdfEditSession session) =>
        [.. session.Document.Array(session.Document.Pages[0].Dictionary, "Contents")!.Items.Select(i => ((PdfReference)i).Number)];

    [Fact]
    public void OnlyTheStreamThatChangedIsReplacedAndItKeepsItsMarker()
    {
        var session = Split("0.5 g 10 10 50 50 re f", "BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET", "q 1 0 0 rg 100 100 20 20 re f Q");
        Assert.True(new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand").Done);
        var numbers = Numbers(session);
        Assert.Equal(10, numbers[0]);
        Assert.NotEqual(11, numbers[1]);
        Assert.Equal(12, numbers[2]);
        var middle = (PdfStream)session.Document.Resolve(session.Document.Array(session.Document.Pages[0].Dictionary, "Contents")!.Items[1])!;
        Assert.True(middle.Dictionary.ContainsKey("LazyPDF"));
        Assert.Contains("Hello grand world", EditKit.Text(session));
    }

    [Fact]
    public void AnOperationWhoseOperatorIsInTheNextStreamMergesThem()
    {
        var session = Split("0.5 g 10 10 50 50 re f", "BT /F1 12 Tf 50 700 Td (Hello brave world)", "Tj ET", "q 1 0 0 rg 100 100 20 20 re f Q");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        Assert.True(result.Done, result.Problem);
        Assert.Contains("Hello grand world", EditKit.Text(session));
        Assert.Equal(3, Numbers(session).Count);
        Assert.Equal(10, Numbers(session)[0]);
        Assert.Equal(13, Numbers(session)[2]);
        Assert.Contains("Hello grand world", EditKit.Pig(session));
    }

    [Fact]
    public void AStreamAfterTheEditIsLeftAloneWhenTheEditIsInTheFirst()
    {
        var session = Split("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj ET", "q 1 0 0 rg 100 100 20 20 re f Q");
        Assert.True(new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "world"), "there").Done);
        Assert.Equal(11, Numbers(session)[1]);
    }

    [Fact]
    public void ContentAddedAtTheEndStartsFromACleanState()
    {
        var session = Split("q 3 0 0 3 0 0 cm BT /F1 12 Tf 10 100 Td (open) Tj", "5 w");
        var editor = new PageEditor(session, 0);
        Assert.True(editor.AddRectangle(new PdfRect(200, 300, 260, 340), new ShapeStyle(new RgbColor(0, 0, 0))).Done);
        var bounds = EditPaint.Paths(session)[0].Path.Bounds;
        Assert.Equal(new PdfRect(200, 300, 260, 340), bounds);
        Assert.Equal(1, EditPaint.Paths(session)[0].LineWidth);
    }

    [Fact]
    public void ADuplicatedPageSharingItsContentIsNotEditedThroughTheOther()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(5, EditKit.Helvetica);
        pdf.Stream(6, "", "BT /F1 12 Tf 50 700 Td (Shared text) Tj ET");
        var session = PdfEditSession.Open(pdf.Finish());
        Assert.True(new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "Shared"), "Edited").Done);
        Assert.Contains("Edited text", EditKit.Text(session, 0));
        Assert.Contains("Shared text", EditKit.Text(session, 1));
    }

    [Fact]
    public void MalformedContentIsReadAsFarAsItGoes()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Hello brave world) Tj 1 2 3 foo ET\n(unterminated ] >> Tj");
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "brave"), "grand");
        Assert.True(result.Done, result.Problem);
        Assert.Contains("Hello grand world", EditKit.Text(session));
        Assert.Contains("1 2 3 foo ET", EditKit.Latin(session));
    }

    [Fact]
    public void APageWithNoContentHasNothingToEdit()
    {
        var session = EditKit.Session("");
        var editor = new PageEditor(session, 0);
        Assert.Empty(editor.Objects);
        Assert.False(editor.ReplaceText(new TextRange(0, 3), "x").Done);
        Assert.False(session.CanUndo);
    }

    [Fact]
    public void FakeBoldTextIsReplacedWithBothCopies()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td (Bold word) Tj ET\nBT /F1 12 Tf 50.3 700 Td (Bold word) Tj ET");
        Assert.True(new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "word"), "text").Done);
        string drawn = string.Concat(EditKit.Glyphs(session).Select(g => g.Text));
        Assert.Equal("Bold textBold text", drawn);
    }
}
