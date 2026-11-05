using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FormStyleTests
{
    private static PdfForm Standard() => PdfForm.Read(FormFixtures.Open());

    private static PdfForm Blank() => PdfForm.Read(AnnotationFixtures.Blank());

    [Fact]
    public void TheOnStateOfACheckBoxIsRenamedAndTheValueFollows()
    {
        var form = Standard();
        form.SetValue("agree", "Yes");

        form.SetExportValue(form.Find("agree")!.Widgets[0], "Accepted");

        var reopened = PdfForm.Read(Reopen(form.Document));
        var field = reopened.Find("agree")!;
        Assert.Equal("Accepted", field.Widgets[0].OnState);
        Assert.Equal("Accepted", field.Widgets[0].Export);
        Assert.True(field.IsChecked);
        Assert.Equal("Accepted", field.Value);
        Assert.NotNull(reopened.Document.Dict(reopened.Document.Dict(field.Widgets[0].Dictionary, "AP"), "N")!["Off"]);
    }

    [Fact]
    public void ARadioButtonCanTakeAnyUnusedValueAndSettingItAgainDoesNothing()
    {
        var form = Standard();

        form.SetExportValue(form.Find("choice")!.Widgets[1], "Second choice");
        form.SetExportValue(form.Find("choice")!.Widgets[1], "Second choice");
        form.SetValue("choice", "Second choice");

        var reopened = PdfForm.Read(Reopen(form.Document));
        Assert.Equal("Second choice", reopened.Find("choice")!.Value);
        Assert.Equal(["a", "Second choice"], reopened.Find("choice")!.Widgets.Select(w => w.OnState));
    }

    [Fact]
    public void AnExportValueAnotherButtonHasIsRefused()
    {
        var form = Standard();

        Assert.Throws<InvalidOperationException>(() => form.SetExportValue(form.Find("choice")!.Widgets[1], "a"));
        Assert.Throws<ArgumentException>(() => form.SetExportValue(form.Find("choice")!.Widgets[1], "Off"));
        Assert.Throws<ArgumentException>(() => form.SetExportValue(form.Find("choice")!.Widgets[1], "  "));
        Assert.Throws<ArgumentException>(() => form.SetExportValue(form.Find("name")!.Widgets[0], "x"));
    }

    [Fact]
    public void ARadioGroupWithOptionsKeepsItsStatesAndChangesTheOption()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Radio, "size", 0, new PdfRect(50, 700, 64, 714)) { ExportValue = "S" });
        form.AddWidget(form.Find("size")!, 0, new PdfRect(100, 700, 114, 714), "M");
        form.Find("size")!.Dictionary["Opt"] = new PdfArray([PdfText.ToObject("S"), PdfText.ToObject("M")]);
        form.Refresh();

        form.SetExportValue(form.Find("size")!.Widgets[1], "Medium");

        var field = PdfForm.Read(Reopen(form.Document)).Find("size")!;
        Assert.Equal(["S", "Medium"], field.Widgets.Select(w => w.Export));
        Assert.Equal(["S", "M"], field.Widgets.Select(w => w.OnState));
    }

    [Fact]
    public void FontSizeAndColourChangeTheDefaultAppearanceAndTheDrawing()
    {
        var form = Standard();
        form.SetValue("name", "Ada");

        form.SetFont(form.Find("name")!, "TiRo");
        form.SetFontSize(form.Find("name")!, 18);
        form.SetTextColor(form.Find("name")!, [1, 0, 0]);

        var field = PdfForm.Read(Reopen(form.Document)).Find("name")!;
        Assert.Equal("/TiRo 18 Tf 1 0 0 rg", field.DefaultAppearance);
        Assert.Equal("Ada", field.Value);
        Assert.Equal("Ada", FormFixtures.Drawn(form.Document, field.Widgets[0]));
        var fonts = form.Document.Dict(form.Document.Dict(form.AcroForm, "DR"), "Font")!;
        Assert.True(fonts.ContainsKey("TiRo"));
    }

    [Fact]
    public void ACheckBoxMarkTakesTheTextColour()
    {
        var form = Standard();
        form.SetValue("agree", "Yes");

        form.SetTextColor(form.Find("agree")!, [0.2, 0.4, 0.6]);

        var widget = form.Find("agree")!.Widgets[0];
        var on = (PdfStream)form.Document.Resolve(form.Document.Dict(form.Document.Dict(widget.Dictionary, "AP"), "N")!["Yes"])!;
        Assert.Contains("0.2 0.4 0.6", System.Text.Encoding.Latin1.GetString(form.Document.Data(on)));
        Assert.True(form.Find("agree")!.IsChecked);
    }

    [Fact]
    public void ABadFontSizeColourOrFontIsRefused()
    {
        var form = Standard();
        var field = form.Find("name")!;

        Assert.Throws<ArgumentException>(() => form.SetFont(field, "Nope"));
        Assert.Throws<ArgumentException>(() => form.SetFontSize(field, -1));
        Assert.Throws<ArgumentException>(() => form.SetFontSize(field, 300));
        Assert.Throws<ArgumentException>(() => form.SetTextColor(field, [1, 2, 3, 4, 5]));
        Assert.Throws<ArgumentException>(() => form.SetTextColor(field, [0, 0]));
        Assert.Throws<ArgumentException>(() => form.SetTextColor(field, [2]));
        Assert.Equal("/Helv 12 Tf 0 0 1 rg", form.Find("name")!.DefaultAppearance);
    }

    [Fact]
    public void TheLookOfATextFieldIsReadFromItsDefaultAppearance()
    {
        var form = Standard();

        var look = form.GetTextLook(form.Find("name")!);

        Assert.Equal("Helv", look.Font);
        Assert.Equal(12, look.Size);
        Assert.Equal([0, 0, 1], look.Color);
        Assert.Equal(0, form.GetTextLook(form.Find("bio")!).Size);
    }

    private static FormField Button(PdfForm form)
    {
        form.AddField(new FieldSpec(FieldKind.PushButton, "go", 0, new PdfRect(300, 100, 400, 124)) { Caption = "Go" });
        return form.Find("go")!;
    }

    [Fact]
    public void AButtonOpensALinkResetsOrSubmits()
    {
        var form = Blank();
        var go = Button(form);

        form.SetButtonAction(go, new ButtonAction(ButtonActionKind.OpenLink, " https://example.com/a "));
        var link = PdfForm.Read(Reopen(form.Document));
        Assert.Equal(new ButtonAction(ButtonActionKind.OpenLink, "https://example.com/a"), link.GetButtonAction(link.Find("go")!));

        form.SetButtonAction(form.Find("go")!, new ButtonAction(ButtonActionKind.Reset));
        Assert.Equal(ButtonActionKind.Reset, form.GetButtonAction(form.Find("go")!).Kind);

        form.SetButtonAction(form.Find("go")!, new ButtonAction(ButtonActionKind.Submit, "https://example.com/post"));
        var read = PdfForm.Read(Reopen(form.Document));
        Assert.Equal(new ButtonAction(ButtonActionKind.Submit, "https://example.com/post"), read.GetButtonAction(read.Find("go")!));
        var submit = Assert.IsType<SubmitFormAction>(PdfActions.Read(read.Document, read.Find("go")!.Widgets[0].Dictionary["A"]));
        Assert.Equal(4, submit.Flags);
    }

    [Fact]
    public void AButtonShowsOrHidesAFieldAndCanLoseItsAction()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "notes", 0, new PdfRect(50, 600, 250, 620)));
        var go = Button(form);

        form.SetButtonAction(go, new ButtonAction(ButtonActionKind.Hide, "notes"));
        var hide = PdfForm.Read(Reopen(form.Document));
        Assert.Equal(new ButtonAction(ButtonActionKind.Hide, "notes"), hide.GetButtonAction(hide.Find("go")!));

        form.SetButtonAction(form.Find("go")!, new ButtonAction(ButtonActionKind.Show, "notes"));
        Assert.Equal(new ButtonAction(ButtonActionKind.Show, "notes"), form.GetButtonAction(form.Find("go")!));

        form.SetButtonAction(form.Find("go")!, new ButtonAction(ButtonActionKind.None));
        Assert.Equal(ButtonActionKind.None, form.GetButtonAction(form.Find("go")!).Kind);
        Assert.Null(form.Find("go")!.Widgets[0].Dictionary["A"]);
    }

    [Fact]
    public void ButtonActionsThatCannotBeWrittenAreRefused()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "notes", 0, new PdfRect(50, 600, 250, 620)));
        var go = Button(form);

        Assert.Throws<ArgumentException>(() => form.SetButtonAction(go, new ButtonAction(ButtonActionKind.OpenLink, " ")));
        Assert.Throws<ArgumentException>(() => form.SetButtonAction(go, new ButtonAction(ButtonActionKind.Other)));
        Assert.Throws<InvalidOperationException>(() => form.SetButtonAction(go, new ButtonAction(ButtonActionKind.Hide, "missing")));
        Assert.Throws<ArgumentException>(() => form.SetButtonAction(form.Find("notes")!, new ButtonAction(ButtonActionKind.Reset)));
        Assert.Null(form.Find("go")!.Widgets[0].Dictionary["A"]);
    }

    [Fact]
    public void AnActionTheEngineDoesNotWriteIsReadAsOther()
    {
        var form = Blank();
        var go = Button(form);
        go.Widgets[0].Dictionary["A"] = new PdfDictionary { ["S"] = new PdfName("JavaScript"), ["JS"] = PdfText.ToObject("app.alert(1)") };

        Assert.Equal(ButtonActionKind.Other, form.GetButtonAction(go).Kind);
    }

    [Fact]
    public void ChangingOnlyTheFontDrawsInThatFont()
    {
        var form = Standard();
        form.SetValue("name", "Ada");

        form.SetFont(form.Find("name")!, "Cour");

        var fonts = form.Document.Dict(form.Document.Dict(form.AcroForm, "DR"), "Font")!;
        Assert.True(fonts.ContainsKey("Cour"));
        var d = form.Document;
        var stream = (PdfStream)d.Resolve(d.Dict(form.Find("name")!.Widgets[0].Dictionary, "AP")!["N"])!;
        var used = d.Dict(d.Dict(stream.Dictionary, "Resources"), "Font")!;
        Assert.All(used.Entries, e => Assert.Equal("Courier", d.Name(d.Dict(used, e.Key), "BaseFont")));
    }

    [Fact]
    public void SizeAndColourSurviveAFieldThatNeedsAnEmbeddedFont()
    {
        var form = PdfForm.Read(AnnotationFixtures.Blank(), new ArialSource());
        form.AddField(new FieldSpec(FieldKind.Text, "tr", 0, new PdfRect(50, 700, 250, 720)) { Value = "Şişli" });

        form.SetFontSize(form.Find("tr")!, 18);
        form.SetTextColor(form.Find("tr")!, [1, 0, 0]);

        var look = form.GetTextLook(form.Find("tr")!);
        Assert.Equal(18, look.Size);
        Assert.Equal([1, 0, 0], look.Color);
    }

    [Fact]
    public void ACheckBoxPlacedTwiceRenamesItsStateEverywhere()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.CheckBox, "ok", 0, new PdfRect(50, 700, 64, 714)));
        form.AddWidget(form.Find("ok")!, 0, new PdfRect(100, 700, 114, 714));
        form.SetValue("ok", "Yes");

        form.SetExportValue(form.Find("ok")!.Widgets[0], "On");

        var field = form.Find("ok")!;
        Assert.All(field.Widgets, w => Assert.Equal("On", w.OnState));
        Assert.True(field.IsChecked);
    }

    [Fact]
    public void ShowAndHideActionsFollowARenameAndGoWithARemovedField()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "notes", 0, new PdfRect(50, 600, 250, 620)));
        form.SetButtonAction(Button(form), new ButtonAction(ButtonActionKind.Hide, "notes"));

        form.Rename(form.Find("notes")!, "remarks");
        Assert.Equal(new ButtonAction(ButtonActionKind.Hide, "remarks"), form.GetButtonAction(form.Find("go")!));

        form.Remove(form.Find("remarks")!);
        Assert.Equal(ButtonActionKind.None, form.GetButtonAction(form.Find("go")!).Kind);
    }
}
