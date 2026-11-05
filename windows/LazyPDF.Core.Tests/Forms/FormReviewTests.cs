using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FormReviewTests
{
    private static readonly PdfRect Box = new(50, 700, 250, 720);

    private static PdfForm Blank() => PdfForm.Read(AnnotationFixtures.Blank());

    private static FormCall Call(string source) => FormScriptParser.Parse(source)![0];

    [Fact]
    public void AddWidgetKeepsTheFirstWidgetOnItsPageWithoutP()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "t", 0, Box));
        form.Find("t")!.Dictionary.Remove("P");

        form.AddWidget(form.Find("t")!, 0, new PdfRect(50, 600, 250, 620));

        var field = form.Find("t")!;
        Assert.Equal([0, 0], field.Widgets.Select(w => w.PageIndex));
        Assert.All(field.Widgets, w => Assert.Equal("Widget", form.Document.Name(w.Dictionary, "Subtype")));
        Assert.True(field.Widgets[1].Dictionary.ContainsKey("MK"));
    }

    [Fact]
    public void ANewRadioButtonDoesNotShareAStateAfterARemoval()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Radio, "r", 0, new PdfRect(50, 700, 64, 714)));
        form.AddWidget(form.Find("r")!, 0, new PdfRect(80, 700, 94, 714));
        form.AddWidget(form.Find("r")!, 0, new PdfRect(110, 700, 124, 714));
        form.Remove(form.Find("r")!.Widgets[1]);
        form.AddWidget(form.Find("r")!, 0, new PdfRect(140, 700, 154, 714));

        var states = form.Find("r")!.Widgets.Select(w => w.OnState).ToList();
        Assert.Equal(states.Count, states.Distinct().Count());
    }

    [Fact]
    public void ADateIsReadInTheFieldsOwnFormat()
    {
        Assert.Equal("03/04/2024", FormFunctions.Format(Call("AFDate_FormatEx(\"dd/mm/yyyy\")"), "03/04/2024")?.Text);
    }

    [Fact]
    public void ANumberWithADotGroupMarkKeepsItsValue()
    {
        Assert.Equal("1.234,00", FormFunctions.Format(Call("AFNumber_Format(2, 2, 0, 0, \"\", true)"), "1.234")?.Text);
    }

    [Fact]
    public void ALongPhoneNumberIsShownWhole()
    {
        Assert.Null(FormFunctions.Format(Call("AFSpecial_Format(2)"), "123456789012"));
    }

    [Fact]
    public void RedrawingAnIconButtonLeavesItsAppearance()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.PushButton, "go", 0, new PdfRect(50, 700, 150, 730)));
        var widget = form.Find("go")!.Widgets[0];
        widget.Dictionary["MK"] = new PdfDictionary { ["I"] = new PdfReference(1, 0), ["CA"] = PdfText.ToObject("x") };
        var before = widget.Dictionary["AP"];

        form.Move(widget, 10, 0);

        Assert.Same(before, form.Find("go")!.Widgets[0].Dictionary["AP"]);
    }

    [Fact]
    public void PartialFlattenLeavesNoDeadFieldEntries()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "a", 0, Box) { Value = "x" });
        form.AddField(new FieldSpec(FieldKind.Text, "b", 0, new PdfRect(50, 600, 250, 620)));

        form.Flatten([form.Find("a")!]);

        var fields = form.Document.Array(form.AcroForm, "Fields")!;
        Assert.Single(fields.Items);
        Assert.NotNull(form.Document.Resolve(fields.Items[0]));
    }

    [Fact]
    public void ClearingAFlagTheParentSetsWritesAnExplicitZero()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "g.t", 0, Box));
        var field = form.Find("g.t")!;
        var parent = form.Document.Dict(field.Dictionary, "Parent")!;
        parent["Ff"] = new PdfNumber(1);
        field.Dictionary["Ff"] = new PdfNumber(1);
        form = PdfForm.Read(form.Document);
        field = form.Find("g.t")!;
        Assert.True(field.Has(FieldFlags.ReadOnly));

        form.SetFlag(field, FieldFlags.ReadOnly, false);

        Assert.False(form.Find("g.t")!.Has(FieldFlags.ReadOnly));
    }

    [Fact]
    public void ACheckBoxWithAStringValueIsExportedAsItsOnState()
    {
        var form = PdfForm.Read(FormFixtures.Open());
        var box = form.Find("agree")!;
        box.Dictionary["V"] = PdfText.ToObject("Yes");
        box.Widgets[0].Dictionary["AS"] = new PdfName("Yes");
        form = PdfForm.Read(form.Document);
        Assert.True(form.Find("agree")!.IsChecked);

        var value = form.ExportFdf().Fields.Single(f => f.Name == "agree").Value;
        Assert.Equal("Yes", ((PdfName)value!).Value);
    }

    [Fact]
    public void AToUnicodeEntryThatIsHalfOfAPairDoesNotStopTheDrawing()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R] /DR <</Font <</Helv 11 0 R>>>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R]>>");
        pdf.Obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T (t) /DA (/Helv 12 Tf 0 g) /Rect [0 0 100 20] /P 3 0 R>>");
        pdf.Obj(11, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 12 0 R>>");
        pdf.Stream(12, "", "begincmap 1 begincodespacerange <00> <FF> endcodespacerange 1 beginbfchar <41> <D800> endbfchar endcmap");
        var form = PdfForm.Read(PdfDocument.Open(pdf.Finish()));

        form.SetValue("t", "B");

        Assert.Equal("B", FormFixtures.Drawn(form.Document, form.Find("t")!.Widgets[0]));
    }

    [Fact]
    public void APercentTooLargeToShowFallsBackToTheRawValue()
    {
        string huge = "1" + new string('0', 307);

        Assert.Null(FormFunctions.Format(Call("AFPercent_Format(2, 0)"), huge));
    }

    [Fact]
    public void ALargeWholeNumberIsWrittenAsItIs()
    {
        Assert.Equal("2000000000000000", FormFunctions.NumberText(2e15));
        Assert.Equal("1234567890123456", FormFunctions.NumberText(1234567890123456));
        Assert.Equal("20000000000000000", FormFunctions.NumberText(2e16));
        Assert.Equal("1E+17", FormFunctions.NumberText(1e17));
    }

    [Theory]
    [InlineData("mmmm d, yyyy", "12/25/35", "December 25, 2035")]
    [InlineData("mmmm d, yyyy", "12/25/50", "December 25, 1950")]
    [InlineData("dd/mm/yyyy hh:MM", "03/04/2024 05:30", "03/04/2024 05:30")]
    [InlineData("HHH:MM", "05:30", "05:30")]
    public void ADateOrTimeIsReadByTheFieldsOwnFormat(string format, string value, string shown)
    {
        Assert.Equal(shown, FormFunctions.Format(Call($"AFDate_FormatEx(\"{format}\")"), value)?.Text);
    }

    [Fact]
    public void ALongRunOfHourLettersIsNotADate()
    {
        Assert.Null(FormFunctions.Format(Call($"AFDate_FormatEx(\"{new string('H', 20)}\")"), "99999999999999999999"));
    }

    [Fact]
    public void AWidgetKeptAcrossAChangeStillBelongsToItsField()
    {
        var form = Blank();
        var field = form.AddField(new FieldSpec(FieldKind.Text, "t", 0, Box));
        var widget = form.AddWidget(field, 0, new PdfRect(50, 600, 250, 620));
        form.SetValue("t", "x");

        form.Resize(widget, new PdfRect(50, 600, 350, 640));
        form.Remove(widget);

        Assert.Single(form.Find("t")!.Widgets);
        Assert.Equal("x", FormFixtures.Drawn(form.Document, form.Find("t")!.Widgets[0]));
    }

    [Fact]
    public void NamesThatDifferOnlyInHowAnAccentIsWrittenAreTwoFields()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 11 0 R] /DA (/Helv 0 Tf 0 g)>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>");
        pdf.Obj(10, "<</Type /Annot /Subtype /Widget /FT /Tx /T <FEFF00E9> /Rect [0 0 100 20] /P 3 0 R>>");
        pdf.Obj(11, "<</Type /Annot /Subtype /Widget /FT /Tx /T <FEFF00650301> /Rect [0 30 100 50] /P 3 0 R>>");
        var form = PdfForm.Read(PdfDocument.Open(pdf.Finish()));

        Assert.Equal(2, form.Fields.Count);
        Assert.Single(form.FindAll("\u00E9"));
        Assert.Single(form.FindAll("e\u0301"));
        Assert.Equal(2, form.ExportFdf().Fields.Count);
        Assert.Equal(2, FormCsv.Read(form.ExportCsv())[0].Count());
    }
}
