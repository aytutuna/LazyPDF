using Xunit;

namespace LazyPDF.Core.Tests;

public class WidgetFontTests
{
    private static PdfDocument TwoWidgets()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 4 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [10 0 R] /Count 1 /MediaBox [0 0 300 300]>>");
        pdf.Obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding>>");
        pdf.Obj(4, "<</Fields [20 0 R] /DA (/Helv 12 Tf 0 g) /DR <</Font <</Helv 3 0 R /Cour 5 0 R>>>>>>");
        pdf.Obj(10, "<</Type /Page /Parent 2 0 R /Annots [21 0 R 22 0 R]>>");
        pdf.Obj(20, "<</FT /Tx /T (t) /Kids [21 0 R 22 0 R] /DA (/Helv 12 Tf 0 g)>>");
        pdf.Obj(21, "<</Type /Annot /Subtype /Widget /Parent 20 0 R /Rect [20 20 200 40] /F 4 /P 10 0 R>>");
        pdf.Obj(22, "<</Type /Annot /Subtype /Widget /Parent 20 0 R /Rect [20 60 200 80] /F 4 /P 10 0 R /DA (/Cour 10 Tf 0 g)>>");
        return PdfDocument.Open(pdf.Finish());
    }

    private static string BaseFontOf(PdfDocument document, PdfDictionary widget)
    {
        var appearance = (PdfStream)document.Resolve(document.Dict(widget, "AP")!["N"])!;
        var fonts = document.Dict(document.Dict(appearance.Dictionary, "Resources"), "Font")!;
        return document.Name(document.Dict(fonts, fonts.Entries.Single().Key), "BaseFont")!;
    }

    [Fact]
    public void AWidgetWithItsOwnDefaultAppearanceIsRedrawnInThatFont()
    {
        var document = TwoWidgets();
        PdfForm.Read(document).SetValue("t", "hello");
        var bytes = document.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);

        var again = PdfDocument.Open(bytes);
        var widgets = PdfForm.Read(again).Find("t")!.Widgets;
        Assert.Equal("Helvetica", BaseFontOf(again, widgets[0].Dictionary));
        Assert.Equal("Courier", BaseFontOf(again, widgets[1].Dictionary));
    }
}
