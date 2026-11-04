using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// With LAZYPDF_EDIT_OUT set to a folder, writes a page before and after a run of edits, to be drawn and looked at.
public class EditSampleTests
{
    [Fact]
    public void ABusyPageSurvivesARunOfEdits()
    {
        var jpeg = EditPaint.Jpeg();
        string content =
            "0.9 0.9 1 rg 40 560 520 200 re f\n" +
            "BT /F2 24 Tf 0 0 0.5 rg 60 720 Td (Quarterly report) Tj ET\n" +
            "BT /F1 12 Tf 0 g 14 TL 60 690 Td (The quick brown fox jumps over) Tj T* (the lazy dog and keeps running) Tj T* (until the end of the day) Tj ET\n" +
            "q 120 0 0 90 60 450 cm /Im1 Do Q\n" +
            "q 90 0 0 90 220 450 cm /Im2 Do Q\n" +
            "1 0 0 rg 0 0 1 RG 3 w 380 450 120 90 re B\n" +
            "BT /F1 10 Tf 0 g 60 400 Td (footnote one) Tj ET\n";
        var session = PdfEditSession.Open(EditKit.File(content, more: pdf =>
        {
            pdf.Stream(7, "/Type /XObject /Subtype /Image /Width 8 /Height 6 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg);
            pdf.Stream(8, "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8", [0, 255, 255, 0]);
        }, resources: "/Font <</F1 5 0 R /F2 6 0 R>> /XObject <</Im1 7 0 R /Im2 8 0 R>>"));
        string? folder = Environment.GetEnvironmentVariable("LAZYPDF_EDIT_OUT");
        if (folder is not null)
        {
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(Path.Combine(folder, "before.pdf"), session.Current.ToArray());
        }

        var fonts = new EditArialSource();
        var editor = new PageEditor(session, 0, fonts);
        Assert.True(editor.ReplaceText(EditKit.Find(session, "Quarterly"), "Yıllık").Done);
        editor = new PageEditor(session, 0, fonts);
        Assert.True(editor.SetTextStyle([EditKit.Find(session, "brown fox")], new TextStyleChange(Bold: true, Color: new RgbColor(180, 0, 0))).Done);
        editor = new PageEditor(session, 0, fonts);
        var paragraph = editor.Objects.OfType<TextObject>().First(t => t.Text.StartsWith("The quick"));
        Assert.True(editor.ReplaceParagraph(paragraph, "Çalışma raporu: the quick brown fox jumps over the lazy dog and keeps running until the end of the day, then rests").Done);
        editor = new PageEditor(session, 0, fonts);
        var images = editor.Objects.OfType<ImageObject>().ToList();
        Assert.True(editor.Rotate([images[0]], 20).Done);
        editor = new PageEditor(session, 0, fonts);
        Assert.True(editor.Crop(editor.Objects.OfType<ImageObject>().Last(), new PdfRect(220, 450, 280, 520)).Done);
        editor = new PageEditor(session, 0, fonts);
        Assert.True(editor.SetPathStyle(editor.Objects.OfType<PathObject>().Skip(1), fill: new RgbColor(0, 150, 0), lineWidth: 6).Done);
        editor = new PageEditor(session, 0, fonts);
        Assert.True(editor.AddEllipse(new PdfRect(380, 330, 500, 400), new ShapeStyle(new RgbColor(0, 0, 0), new RgbColor(255, 220, 0), 2)).Done);
        editor = new PageEditor(session, 0, fonts);
        Assert.True(editor.AddTextBox(new PdfRect(60, 280, 300, 380), "Yeni metin kutusu: ğüşiöç wraps inside its box and stays upright.", new TextBoxStyle(Family: "Arial", Size: 12, Color: new RgbColor(0, 100, 0))).Done);
        editor = new PageEditor(session, 0, fonts);
        Assert.True(editor.Move(editor.Objects.Where(o => o is TextObject t && t.Text.StartsWith("footnote")), 240, 0).Done);
        if (folder is not null) File.WriteAllBytes(Path.Combine(folder, "after.pdf"), session.Current.ToArray());

        using var pig = UglyToad.PdfPig.PdfDocument.Open(session.Current.ToArray());
        Assert.Contains("Yıllık", pig.GetPage(1).Text);
        while (session.CanUndo) session.Undo();
        Assert.Equal(content.Length, EditKit.Latin(session).Length);
    }
}
