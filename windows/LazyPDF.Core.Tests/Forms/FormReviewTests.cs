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
}
