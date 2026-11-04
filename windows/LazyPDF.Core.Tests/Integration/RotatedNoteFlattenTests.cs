using Xunit;

namespace LazyPDF.Core.Tests;

public class RotatedNoteFlattenTests
{
    private sealed class FormCatcher : ContentVisitor
    {
        public List<FormInfo> Forms { get; } = [];

        public override void BeginForm(ContentContext context, FormInfo form) => Forms.Add(form);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void AFlattenedNoteStaysUprightWhereItsCornerWas(int rotate)
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(1, pageExtra: $"/Rotate {rotate}"));
        var page = document.Pages[0];
        var geometry = new PageGeometry(page);
        var rect = new PdfRect(100, 300, 120, 320);
        new PdfAnnotationWriter(document).AddNote(page, rect, new AnnotationInfo("A", "text"));

        Assert.Equal(1, PdfAnnotationFlattener.Flatten(document, page, new HashSet<AnnotationType> { AnnotationType.Text }));
        var bytes = document.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);

        var again = PdfDocument.Open(bytes);
        var catcher = new FormCatcher();
        new ContentInterpreter(again).Run(again.Pages[0], catcher);
        var form = Assert.Single(catcher.Forms);

        var anchor = geometry.ToDisplay(rect);
        var shown = geometry.ToDisplay(form.Bounds);
        Assert.Equal(anchor.X, shown.X, 3);
        Assert.Equal(anchor.Y, shown.Y, 3);
        Assert.Equal(20, shown.Width, 3);
        Assert.Equal(20, shown.Height, 3);

        var origin = geometry.ToDisplay(form.Matrix.Transform(0, 0).X, form.Matrix.Transform(0, 0).Y);
        var along = geometry.ToDisplay(form.Matrix.Transform(1, 0).X, form.Matrix.Transform(1, 0).Y);
        var up = geometry.ToDisplay(form.Matrix.Transform(0, 1).X, form.Matrix.Transform(0, 1).Y);
        Assert.Equal(1, along.X - origin.X, 6);
        Assert.Equal(0, along.Y - origin.Y, 6);
        Assert.Equal(0, up.X - origin.X, 6);
        Assert.Equal(-1, up.Y - origin.Y, 6);
    }

    [Fact]
    public void AnAnnotationWithoutTheFlagTurnsWithThePage()
    {
        var document = PdfDocument.Open(IntegrationFiles.Form(1, pageExtra: "/Rotate 90"));
        var page = document.Pages[0];
        var writer = new PdfAnnotationWriter(document);
        writer.AddSquare(page, new PdfRect(100, 300, 160, 320));
        Assert.Equal(1, PdfAnnotationFlattener.Flatten(document, page, new HashSet<AnnotationType> { AnnotationType.Square }));

        var catcher = new FormCatcher();
        new ContentInterpreter(document).Run(page, catcher);
        var shown = new PageGeometry(page).ToDisplay(Assert.Single(catcher.Forms).Bounds);
        Assert.Equal(20, shown.Width, 3);
        Assert.Equal(60, shown.Height, 3);
    }
}
