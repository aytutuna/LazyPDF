using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FieldDetectorTests
{
    private const string Page = """
        BT /F1 12 Tf 50 700 Td (Name:) Tj ET
        0.5 w 100 698 m 300 698 l S
        BT /F1 12 Tf 50 650 Td (Address: ____________) Tj ET
        50 600 10 10 re S
        BT /F1 12 Tf 66 601 Td (I agree) Tj ET
        BT /F1 12 Tf 50 560 Td (Code) Tj ET
        100 550 14 18 re S 114 550 14 18 re S 128 550 14 18 re S 142 550 14 18 re S 156 550 14 18 re S 170 550 14 18 re S
        BT /F1 12 Tf 50 500 Td (Phone:) Tj ET
        61 455 m 61 458.314 58.314 461 55 461 c 51.686 461 49 458.314 49 455 c 49 451.686 51.686 449 55 449 c 58.314 449 61 451.686 61 455 c h S
        BT /F1 12 Tf 66 452 Td (Choice) Tj ET
        0.8 g 50 380 100 20 re f 0 g
        BT /F1 12 Tf 300 300 Td (Printed text) Tj ET
        300 298 m 420 298 l S
        50 200 m 250 200 l S 50 200 m 50 230 l S 250 200 m 250 230 l S
        """;

    private static PdfDocument Open(string content, string widgets = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [" + (widgets.Length > 0 ? "6 0 R" : "") + "] /DA (/Helv 0 Tf 0 g)>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>>>>>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [{(widgets.Length > 0 ? "6 0 R" : "")}]>>");
        pdf.Stream(4, "", content);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        if (widgets.Length > 0) pdf.Obj(6, widgets);
        return PdfDocument.Open(pdf.Finish());
    }

    private static IReadOnlyList<FieldProposal> Detect(string content, string widgets = "") => FieldDetector.Detect(Open(content, widgets), 0);

    [Fact]
    public void RuledLinesUnderscoresBoxesAndColonGapsAreProposed()
    {
        var found = Detect(Page);

        var line = Assert.Single(found, p => p.Label == "Name");
        Assert.Equal(FieldKind.Text, line.Kind);
        Assert.Equal(100, line.Rect.Left, 0.5);
        Assert.Equal(300, line.Rect.Right, 0.5);
        Assert.InRange(line.Rect.Bottom, 698, 700);

        var underscores = Assert.Single(found, p => p.Label == "Address");
        Assert.Equal(FieldKind.Text, underscores.Kind);
        Assert.True(underscores.Rect.Width > 60);

        var check = Assert.Single(found, p => p.Kind == FieldKind.CheckBox);
        Assert.Equal("I agree", check.Label);
        Assert.Equal(new PdfRect(50, 600, 60, 610), check.Rect);

        var comb = Assert.Single(found, p => p.Cells > 0);
        Assert.Equal(6, comb.Cells);
        Assert.Equal("Code", comb.Label);
        Assert.Equal(new PdfRect(100, 550, 184, 568), comb.Rect);

        var phone = Assert.Single(found, p => p.Label == "Phone");
        Assert.Equal(FieldKind.Text, phone.Kind);
        Assert.True(phone.Rect.Left > 80 && phone.Rect.Width >= 100);

        var radio = Assert.Single(found, p => p.Kind == FieldKind.Radio);
        Assert.Equal("Choice", radio.Label);
        Assert.Equal(12, radio.Rect.Width, 0.5);
    }

    [Fact]
    public void FilledBlanksBarsAndClosedCellsAreNotProposed()
    {
        var found = Detect(Page);

        Assert.DoesNotContain(found, p => p.Rect.Left >= 295 && p.Rect.Bottom is > 290 and < 330);
        Assert.DoesNotContain(found, p => p.Rect.Bottom is > 370 and < 410);
        Assert.DoesNotContain(found, p => p.Rect.Bottom is > 190 and < 240);
        Assert.Equal(6, found.Count);
    }

    [Fact]
    public void ExistingFieldsAreNotProposedAgainAndNamesAreUnique()
    {
        string widget = "<</Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [100 699 300 715] /P 3 0 R>>";

        var found = Detect(Page, widget);

        Assert.DoesNotContain(found, p => p.Label == "Name");
        var again = Detect("BT /F1 12 Tf 50 700 Td (Name:) Tj ET 100 698 m 300 698 l S BT /F1 12 Tf 50 650 Td (Name:) Tj ET 100 648 m 300 648 l S");
        Assert.Equal(["Name", "Name2"], again.Select(p => p.Name));
    }

    [Fact]
    public void ProposalsAreAcceptedByAddingThemAsFields()
    {
        var document = Open(Page);
        var form = PdfForm.Read(document);
        var proposals = FieldDetector.Detect(document);

        foreach (var p in proposals) form.AddField(p.ToSpec());

        Assert.Equal(proposals.Count, form.Fields.Count);
        Assert.Equal(6, form.Find("Code")!.MaxLength);
        Assert.True(form.Find("Code")!.Has(FieldFlags.Comb));
        Assert.Equal(proposals.Select(p => p.Name).Order(), PdfForm.Read(Reopen(document)).Fields.Select(f => f.Name).Order());
        Assert.Empty(FieldDetector.Detect(document));
    }

    [Fact]
    public void PagesWithoutVectorContentGiveNothing()
    {
        Assert.Empty(FieldDetector.Detect(AnnotationFixtures.Blank(), 0));
        Assert.Empty(Detect("BT /F1 12 Tf 50 700 Td (Just a sentence on the page.) Tj ET"));
    }

    [Fact]
    public void BrokenContentDoesNotThrow()
    {
        Assert.Empty(Detect("q q q Q Q Q Q ) ] >> BT (x) Tj"));
    }
}
