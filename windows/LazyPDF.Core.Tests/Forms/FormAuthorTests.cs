using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FormAuthorTests
{
    private static readonly PdfRect Box = new(50, 700, 250, 720);

    private static PdfForm Blank(IFontSource? fonts = null) => PdfForm.Read(AnnotationFixtures.Blank(), fonts);

    private static int PigFields(PdfDocument document)
    {
        using var pig = UglyToad.PdfPig.PdfDocument.Open(document.SaveRewrite());
        return pig.TryGetForm(out var form) ? form.Fields.Count : 0;
    }

    [Fact]
    public void ATextFieldGetsAWidgetAnAppearanceAndAFormToLiveIn()
    {
        var form = Blank();

        var field = form.AddField(new FieldSpec(FieldKind.Text, "first", 0, Box) { Value = "Ada", Tooltip = "Given name", Flags = FieldFlags.Required });

        Assert.Equal("first", field.Name);
        Assert.Equal("Ada", field.Value);
        Assert.Equal("Given name", field.Tooltip);
        Assert.True(field.Has(FieldFlags.Required));
        Assert.Equal(Box, field.Widgets[0].Rect);
        Assert.Equal(0, field.Widgets[0].PageIndex);
        Assert.Equal("Ada", FormFixtures.Drawn(form.Document, field.Widgets[0]));
        Assert.Contains(field.Reference, form.Document.Array(form.Document.Pages[0].Dictionary, "Annots")!.Items);
        var reopened = PdfForm.Read(Reopen(form.Document));
        Assert.Equal("Ada", reopened.Find("first")!.Value);
        Assert.Equal(1, PigFields(form.Document));
    }

    [Fact]
    public void EveryKindCanBeAddedAndReadBack()
    {
        var form = Blank();
        double y = 700;
        PdfRect Next() => new(50, y -= 40, 250, y + 30);

        form.AddField(new FieldSpec(FieldKind.Text, "t", 0, Next()) { Flags = FieldFlags.Multiline | FieldFlags.Password });
        form.AddField(new FieldSpec(FieldKind.Text, "comb", 0, Next()) { MaxLength = 8, Flags = FieldFlags.Comb, Value = "123" });
        form.AddField(new FieldSpec(FieldKind.CheckBox, "c", 0, Next()) { ExportValue = "On", Value = "On" });
        form.AddField(new FieldSpec(FieldKind.Radio, "r", 0, Next()) { ExportValue = "one", Value = "one" });
        form.AddField(new FieldSpec(FieldKind.PushButton, "go", 0, Next()) { Caption = "Send", Background = [0.8], BorderStyle = BorderStyle.Beveled });
        form.AddField(new FieldSpec(FieldKind.ComboBox, "combo", 0, Next()) { Options = [new("a"), new("b", "Bee")], Value = "Bee", DefaultValue = "a" });
        form.AddField(new FieldSpec(FieldKind.ListBox, "list", 0, Next()) { Options = [new("x"), new("y"), new("z")], Flags = FieldFlags.MultiSelect, Value = "x; z" });
        form.AddField(new FieldSpec(FieldKind.Signature, "sig", 0, Next()));

        var read = PdfForm.Read(Reopen(form.Document));
        Assert.Equal(
            [FieldKind.Text, FieldKind.Text, FieldKind.CheckBox, FieldKind.Radio, FieldKind.PushButton, FieldKind.ComboBox, FieldKind.ListBox, FieldKind.Signature],
            read.Fields.Select(f => f.Kind));
        Assert.True(read.Find("t")!.Has(FieldFlags.Password));
        Assert.Equal("123", read.Find("comb")!.Value);
        Assert.Equal(8, read.Find("comb")!.MaxLength);
        Assert.True(read.Find("c")!.IsChecked);
        Assert.Equal("one", read.Find("r")!.Value);
        Assert.Equal("b", read.Find("combo")!.Value);
        Assert.Equal("a", read.Find("combo")!.DefaultValue);
        Assert.Equal(["x", "z"], read.Find("list")!.Selected);
        Assert.Equal("Send", FormFixtures.Drawn(read.Document, read.Find("go")!.Widgets[0]));
        Assert.Equal(8, PigFields(form.Document));
    }

    [Fact]
    public void RadioGroupGrowsWithAddWidget()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Radio, "size", 0, new PdfRect(50, 700, 64, 714)) { ExportValue = "S" });
        var field = form.Find("size")!;

        form.AddWidget(field, 0, new PdfRect(100, 700, 114, 714), "M");
        form.AddWidget(form.Find("size")!, 0, new PdfRect(150, 700, 164, 714), "L");
        form.SetValue("size", "M");

        field = form.Find("size")!;
        Assert.Equal(["S", "M", "L"], field.Widgets.Select(w => w.OnState));
        Assert.Equal(["Off", "M", "Off"], field.Widgets.Select(w => form.Document.Name(w.Dictionary, "AS")));
        Assert.Equal("M", field.Value);
        Reopen(form.Document);
    }

    [Fact]
    public void ATextFieldCanBeShownInTwoPlaces()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "twice", 0, Box));

        form.AddWidget(form.Find("twice")!, 1, new PdfRect(10, 10, 110, 30));
        form.SetValue("twice", "same");

        var field = form.Find("twice")!;
        Assert.Equal([0, 1], field.Widgets.Select(w => w.PageIndex));
        Assert.All(field.Widgets, w => Assert.Equal("same", FormFixtures.Drawn(form.Document, w)));
        Assert.Equal("same", PdfForm.Read(Reopen(form.Document)).Find("twice")!.Value);
    }

    [Fact]
    public void DottedNamesMakeParentsAndNamesAreUnique()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "person.first", 0, Box));
        form.AddField(new FieldSpec(FieldKind.Text, "person.last", 0, new PdfRect(50, 660, 250, 680)));

        Assert.Equal(["person.first", "person.last"], form.Fields.Select(f => f.Name));
        Assert.Single(form.Document.Array(form.AcroForm, "Fields")!.Items);
        Assert.Throws<InvalidOperationException>(() => form.AddField(new FieldSpec(FieldKind.Text, "person.first", 0, Box)));
        Assert.Throws<InvalidOperationException>(() => form.AddField(new FieldSpec(FieldKind.Text, "person", 0, Box)));
        Assert.Throws<InvalidOperationException>(() => form.AddField(new FieldSpec(FieldKind.Text, "person.first.x", 0, Box)));
        Assert.Throws<ArgumentException>(() => form.AddField(new FieldSpec(FieldKind.Text, "bad.", 0, Box)));
        Assert.Throws<ArgumentException>(() => form.AddField(new FieldSpec(FieldKind.Text, "a..b", 0, Box)));
        Assert.Throws<ArgumentException>(() => form.AddField(new FieldSpec(FieldKind.Text, "ok", 9, Box)));
        Assert.Throws<ArgumentException>(() => form.AddField(new FieldSpec(FieldKind.Text, "ok", 0, new PdfRect(1, 1, 1, 5))));
        Assert.Equal(2, PdfForm.Read(Reopen(form.Document)).Fields.Count);
    }

    [Fact]
    public void MovingAndResizingRedrawTheAppearance()
    {
        var form = Blank();
        var field = form.AddField(new FieldSpec(FieldKind.Text, "a", 0, Box) { Value = "text" });

        form.Move(field.Widgets[0], 10, -100);
        form.Resize(form.Find("a")!.Widgets[0], new PdfRect(60, 600, 360, 640));

        var widget = form.Find("a")!.Widgets[0];
        Assert.Equal(new PdfRect(60, 600, 360, 640), widget.Rect);
        var stream = (PdfStream)form.Document.Resolve(form.Document.Dict(widget.Dictionary, "AP")!["N"])!;
        Assert.Equal([0.0, 0.0, 300.0, 40.0], form.Document.Array(stream.Dictionary, "BBox")!.Items.Select(i => ((PdfNumber)i).Value));
        Assert.Equal("text", FormFixtures.Drawn(form.Document, widget));
        Assert.Throws<ArgumentException>(() => form.Resize(widget, new PdfRect(1, 1, 1, 1)));
    }

    [Fact]
    public void RemovingAFieldTakesItsWidgetsAndEmptyParents()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "g.one", 0, Box));
        form.AddField(new FieldSpec(FieldKind.Text, "keep", 0, new PdfRect(50, 600, 250, 620)));
        form.AddField(new FieldSpec(FieldKind.Radio, "r", 0, new PdfRect(50, 500, 64, 514)) { ExportValue = "a" });
        form.AddWidget(form.Find("r")!, 0, new PdfRect(80, 500, 94, 514), "b");

        form.Remove(form.Find("g.one")!);
        Assert.Equal(["keep", "r"], form.Fields.Select(f => f.Name));
        Assert.Equal(2, form.Document.Array(form.AcroForm, "Fields")!.Items.Count);

        form.Remove(form.Find("r")!.Widgets[1]);
        Assert.Single(form.Find("r")!.Widgets);
        form.Remove(form.Find("r")!.Widgets[0]);
        Assert.Null(form.Find("r"));
        Assert.Single(form.Document.Array(form.Document.Pages[0].Dictionary, "Annots")!.Items);
        Assert.Single(PdfForm.Read(Reopen(form.Document)).Fields);
    }

    [Fact]
    public void RenamingChangesTheFullNameAndMayMoveTheField()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "old", 0, Box) { Value = "v", DefaultValue = "d" });
        form.AddField(new FieldSpec(FieldKind.Text, "grp.a", 0, new PdfRect(50, 650, 250, 670)));

        form.Rename(form.Find("old")!, "new");
        Assert.Equal("v", form.Find("new")!.Value);
        Assert.Null(form.Find("old"));

        form.Rename(form.Find("new")!, "grp.b");
        Assert.Equal(["grp.a", "grp.b"], form.Fields.Select(f => f.Name).Order());
        Assert.Equal("d", form.Find("grp.b")!.DefaultValue);

        form.Rename(form.Find("grp.a")!, "solo");
        form.Rename(form.Find("grp.b")!, "solo2");
        Assert.Equal(["solo", "solo2"], form.Fields.Select(f => f.Name).Order());
        Assert.Equal(2, form.Document.Array(form.AcroForm, "Fields")!.Items.Count);
        Assert.Throws<InvalidOperationException>(() => form.Rename(form.Find("solo")!, "solo2"));
        Assert.Equal(["solo", "solo2"], PdfForm.Read(Reopen(form.Document)).Fields.Select(f => f.Name).Order());
    }

    [Fact]
    public void FlagsTooltipOptionsAndDefaultsCanBeChangedLater()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.ComboBox, "c", 0, Box) { Options = [new("a")] });
        var field = form.Find("c")!;

        form.SetFlag(field, FieldFlags.ReadOnly, true);
        form.SetFlag(form.Find("c")!, FieldFlags.Required, true);
        form.SetTooltip(form.Find("c")!, "pick one");
        form.SetOptions(form.Find("c")!, [new("a"), new("b", "Bee")]);
        form.SetDefaultValue(form.Find("c")!, "b");

        field = form.Find("c")!;
        Assert.True(field.Has(FieldFlags.ReadOnly | FieldFlags.Required | FieldFlags.Combo));
        Assert.Equal("pick one", field.Tooltip);
        Assert.Equal(2, field.Options.Count);
        Assert.Equal("b", field.DefaultValue);
        form.SetFlag(field, FieldFlags.ReadOnly, false);
        Assert.False(form.Find("c")!.Has(FieldFlags.ReadOnly));
        Assert.Throws<ArgumentException>(() => form.SetFlag(field, FieldFlags.Radio, true));
        form.Reset();
        Assert.Equal("b", form.Find("c")!.Value);
    }

    [Fact]
    public void TurkishValuesOfNewFieldsUseAnEmbeddedFont()
    {
        var form = Blank(new ArialSource());

        var field = form.AddField(new FieldSpec(FieldKind.Text, "tr", 0, Box) { Value = "Şişli çağrı" });

        Assert.Equal("Şişli çağrı", FormFixtures.Drawn(form.Document, field.Widgets[0]));
        Reopen(form.Document);
    }

    [Fact]
    public void TabOrderFollowsRowsColumnsOrTheAnnotationList()
    {
        var form = Blank();
        form.AddField(new FieldSpec(FieldKind.Text, "bottomLeft", 0, new PdfRect(50, 100, 150, 120)));
        form.AddField(new FieldSpec(FieldKind.Text, "topRight", 0, new PdfRect(300, 400, 400, 420)));
        form.AddField(new FieldSpec(FieldKind.Text, "topLeft", 0, new PdfRect(50, 401, 150, 421)));
        form.AddField(new FieldSpec(FieldKind.Text, "bottomRight", 0, new PdfRect(300, 100, 400, 120)));
        string[] Sequence() => [.. form.TabSequence(0).Select(w => w.Field.Name)];

        Assert.Equal(TabOrder.Annotations, form.GetTabOrder(0));
        Assert.Equal(["bottomLeft", "topRight", "topLeft", "bottomRight"], Sequence());

        form.SetTabOrder(0, TabOrder.Row);
        Assert.Equal(["topLeft", "topRight", "bottomLeft", "bottomRight"], Sequence());
        Assert.Equal("R", form.Document.Name(form.Document.Pages[0].Dictionary, "Tabs"));

        form.SetTabOrder(0, TabOrder.Column);
        Assert.Equal(["topLeft", "bottomLeft", "topRight", "bottomRight"], Sequence());

        var widgets = form.TabSequence(0);
        form.ReorderWidgets(0, [.. widgets.Reverse()]);
        Assert.Equal(TabOrder.Annotations, form.GetTabOrder(0));
        Assert.Equal(["bottomRight", "topRight", "bottomLeft", "topLeft"], Sequence());
        Assert.Equal(["bottomRight", "topRight", "bottomLeft", "topLeft"], PdfForm.Read(Reopen(form.Document)).TabSequence(0).Select(w => w.Field.Name));
    }

    [Fact]
    public void AuthoringDropsAStaticXfaAndDynamicIsRefused()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 12 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        var form = PdfForm.Read(PdfDocument.Open(pdf.Finish()));

        Assert.Throws<PdfReadException>(() => form.AddField(new FieldSpec(FieldKind.Text, "x", 0, Box)));
    }
}
