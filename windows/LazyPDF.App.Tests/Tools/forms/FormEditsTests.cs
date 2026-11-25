using System.Windows;
using LazyPDF.App.Tools.Forms;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What the Forms panel changes in a tab, against real Core calls: one undoable step each, and Core's refusals.
public sealed class FormEditsTests
{
    private static readonly FakeFonts Fonts = new();

    [Fact]
    public void FillingAFieldIsOneUndoableStep()
    {
        using var tab = FormPdfs.Tab();
        int raised = 0;
        tab.Changed += (_, _) => raised++;

        var result = FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("name", "Ada"));

        Assert.Equal(1, result.Filled);
        Assert.Equal(1, raised);
        Assert.Equal("Fill form field", tab.Session.UndoLabel);
        Assert.Equal("Ada", FormPdfs.Read(tab).Find("name")!.Value);
        tab.Undo();
        Assert.Null(FormPdfs.Read(tab).Find("name")!.Value);
    }

    private static Rect Box(FormWidget widget) => new(widget.Rect.Left, widget.Rect.Bottom, widget.Rect.Right - widget.Rect.Left, widget.Rect.Top - widget.Rect.Bottom);

    [Fact]
    public void ManyFieldsMoveTogetherInOneUndoableStep()
    {
        using var tab = FormPdfs.Tab();
        var before = FormPdfs.Read(tab);
        var name = before.Find("name")!.Widgets[0].Rect;
        var code = before.Find("code")!.Widgets[0].Rect;

        FormEdits.Apply(tab, Fonts, "Move form fields", form =>
        {
            FormEdits.ResizeAll(form,
            [
                ("name", 0, 0, new PdfRect(name.Left + 10, name.Bottom - 5, name.Right + 10, name.Top - 5)),
                ("code", 0, 0, new PdfRect(code.Left + 10, code.Bottom - 5, code.Right + 10, code.Top - 5)),
            ]);
            return true;
        });

        var moved = FormPdfs.Read(tab);
        Assert.Equal(name.Left + 10, moved.Find("name")!.Widgets[0].Rect.Left, 3);
        Assert.Equal(code.Bottom - 5, moved.Find("code")!.Widgets[0].Rect.Bottom, 3);
        Assert.Equal("Move form fields", tab.Session.UndoLabel);
        tab.Undo();
        var back = FormPdfs.Read(tab);
        Assert.Equal(name, back.Find("name")!.Widgets[0].Rect);
        Assert.Equal(code, back.Find("code")!.Widgets[0].Rect);
    }

    [Theory]
    [InlineData(AlignKind.Left, new double[] { 50, 50, 50 }, new double[] { 0, 20, 60 })]
    [InlineData(AlignKind.Centre, new double[] { 50, 70, 90 }, new double[] { 0, 20, 60 })]
    [InlineData(AlignKind.Right, new double[] { 50, 90, 130 }, new double[] { 0, 20, 60 })]
    [InlineData(AlignKind.Top, new double[] { 50, 10, 200 }, new double[] { 0, 0, 0 })]
    [InlineData(AlignKind.Middle, new double[] { 50, 10, 200 }, new double[] { 0, -10, 0 })]
    [InlineData(AlignKind.Bottom, new double[] { 50, 10, 200 }, new double[] { 0, -20, 0 })]
    [InlineData(AlignKind.SpaceAcross, new double[] { 85, 10, 200 }, new double[] { 0, 20, 60 })]
    [InlineData(AlignKind.SpaceDown, new double[] { 50, 10, 200 }, new double[] { 0, 20, 60 })]
    public void AligningFollowsTheFirstBoxAndKeepsTheSizes(AlignKind kind, double[] xs, double[] ys)
    {
        Rect[] boxes = [new(50, 0, 100, 10), new(10, 20, 60, 30), new(200, 60, 20, 10)];

        var result = FormEdits.Align(boxes, kind);

        Assert.Equal(xs, result.Select(r => r.X));
        Assert.Equal(ys, result.Select(r => r.Y));
        Assert.Equal(boxes.Select(b => b.Size), result.Select(r => r.Size));
    }

    [Fact]
    public void SpacingDownLeavesEqualGaps()
    {
        Rect[] boxes = [new(0, 0, 10, 10), new(0, 12, 10, 30), new(0, 60, 10, 10)];

        var result = FormEdits.Align(boxes, AlignKind.SpaceDown);

        Assert.Equal(result[1].Y - result[0].Bottom, result[2].Y - result[1].Bottom, 6);
        Assert.Equal(0, result[0].Y);
        Assert.Equal(70, result[2].Bottom);
    }

    [Fact]
    public void AligningLeftIsOneUndoableStep()
    {
        using var tab = FormPdfs.Tab();
        var before = FormPdfs.Read(tab);
        var names = new[] { "name", "code", "agree" };
        var boxes = names.Select(n => Box(before.Find(n)!.Widgets[0])).ToList();
        var aligned = FormEdits.Align(boxes, AlignKind.Left);
        // The test file's page is not turned, so display space differs from user space only by the flip of y.
        var moves = names.Select((n, i) =>
        {
            var rect = before.Find(n)!.Widgets[0].Rect;
            double left = aligned[i].X;
            return (n, 0, 0, new PdfRect(left, rect.Bottom, left + (rect.Right - rect.Left), rect.Top));
        }).ToList();

        FormEdits.Apply(tab, Fonts, "Align form fields", form =>
        {
            FormEdits.ResizeAll(form, moves);
            return true;
        });

        var after = FormPdfs.Read(tab);
        Assert.All(names, n => Assert.Equal(boxes[0].X, after.Find(n)!.Widgets[0].Rect.Left, 3));
        Assert.Equal("Align form fields", tab.Session.UndoLabel);
        tab.Undo();
        var back = FormPdfs.Read(tab);
        Assert.Equal(boxes.Select(b => b.X), names.Select(n => back.Find(n)!.Widgets[0].Rect.Left));
    }

    [Fact]
    public void AMarqueeTouchesEveryWidgetItCrosses()
    {
        var form = FormPdfs.Read(FormPdfs.Tab());

        var touched = FormEdits.Widgets(form, 0, Box).Where(w => w.Box.IntersectsWith(new Rect(50, 570, 120, 100))).Select(w => w.Name).ToList();

        Assert.Equal(["name", "code", "agree"], touched);
    }

    [Fact]
    public void DeletingManyFieldsIsOneUndoableStep()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Delete form fields", form =>
        {
            FormEdits.RemoveAll(form, [("name", 0, 0), ("plan", 1, 0), ("agree", 0, 0)]);
            return true;
        });

        var form = FormPdfs.Read(tab);
        Assert.Null(form.Find("name"));
        Assert.Null(form.Find("agree"));
        Assert.Single(form.Find("plan")!.Widgets);
        Assert.Equal("Delete form fields", tab.Session.UndoLabel);
        tab.Undo();
        form = FormPdfs.Read(tab);
        Assert.NotNull(form.Find("name"));
        Assert.Equal(2, form.Find("plan")!.Widgets.Count);
    }

    [Fact]
    public void PickedWidgetsThatAreGoneAreLeftOut()
    {
        var form = FormPdfs.Read(FormPdfs.Tab());

        var kept = FormEdits.Existing(form, [("name", 0, 0), ("plan", 1, 0), ("plan", 5, 0), ("gone", 0, 0), ("name", 0, 1)]);

        Assert.Equal([("name", 0, 0), ("plan", 1, 0)], kept.OrderBy(k => k.Name));
    }

    [Fact]
    public void TextIsCutAtTheLongestTheFieldTakes()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("code", "123456"));

        Assert.Equal("1234", FormPdfs.Read(tab).Find("code")!.Value);
    }

    [Fact]
    public void ARadioButtonTurnsTheWholeGroup()
    {
        using var tab = FormPdfs.Tab();
        var second = FormPdfs.Read(tab).Find("plan")!.Widgets[1];

        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("plan", second.Export));

        var plan = FormPdfs.Read(tab).Find("plan")!;
        Assert.False(plan.Widgets[0].IsOn);
        Assert.True(plan.Widgets[1].IsOn);
    }

    [Fact]
    public void AListTakesSeveralChoices()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetChoices("langs", ["English", "German"]));

        Assert.Equal(["English", "German"], FormPdfs.Read(tab).Find("langs")!.Selected);
    }

    [Fact]
    public void ARequiredFieldReadsAsRequired()
    {
        using var tab = FormPdfs.Tab();

        Assert.True(FormPdfs.Read(tab).Find("name")!.Has(FieldFlags.Required));
        Assert.False(FormPdfs.Read(tab).Find("code")!.Has(FieldFlags.Required));
    }

    [Fact]
    public async Task AnEditOffTheUiThreadIsCommittedOnceDone()
    {
        using var tab = FormPdfs.Tab();
        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("name", "Ada"));

        int reset = await FormEdits.ApplyAsync(tab, Fonts, "Reset form", form => form.Reset());

        Assert.True(reset > 0);
        Assert.Equal("Reset form", tab.Session.UndoLabel);
        Assert.Null(FormPdfs.Read(tab).Find("name")!.Value);
    }

    [Fact]
    public void FlatteningTakesTheFieldsOut()
    {
        using var tab = FormPdfs.Tab();
        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("name", "Ada"));

        int burned = FormEdits.Apply(tab, Fonts, "Flatten form", form => form.Flatten());

        Assert.Equal(7, burned);
        Assert.Empty(FormPdfs.Read(tab).Fields);
        tab.Undo();
        Assert.Equal(6, FormPdfs.Read(tab).Fields.Count);
    }

    [Fact]
    public void ANewFieldGetsAFreeName()
    {
        using var tab = FormPdfs.Tab();
        var form = FormPdfs.Read(tab);

        Assert.Equal("Text1", FormEdits.NewName(form, FieldKind.Text));
        FormEdits.Add(form, FieldKind.Text, 0, new PdfRect(10, 10, 100, 30), null);
        Assert.Equal("Text2", FormEdits.NewName(FormPdfs.Read(tab), FieldKind.Text));
    }

    [Fact]
    public void ADrawnFieldIsAddedAsOneStep()
    {
        using var tab = FormPdfs.Tab();

        var (name, widget) = FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.CheckBox, 1, new PdfRect(20, 20, 34, 34), null));

        var field = FormPdfs.Read(tab).Find(name)!;
        Assert.Equal(0, widget);
        Assert.Equal(FieldKind.CheckBox, field.Kind);
        Assert.Equal(1, field.Widgets[0].PageIndex);
        tab.Undo();
        Assert.Null(FormPdfs.Read(tab).Find(name));
    }

    [Fact]
    public void ARadioButtonDrawnWhileAGroupIsSelectedJoinsIt()
    {
        using var tab = FormPdfs.Tab();

        var (name, widget) = FormEdits.Apply(tab, Fonts, "Add form field",
            form => FormEdits.Add(form, FieldKind.Radio, 0, new PdfRect(200, 550, 214, 564), form.Find("plan")));

        Assert.Equal("plan", name);
        Assert.Equal(2, widget);
        Assert.Equal(3, FormPdfs.Read(tab).Find("plan")!.Widgets.Count);
    }

    [Fact]
    public void ARadioButtonDrawnAloneStartsAGroup()
    {
        using var tab = FormPdfs.Tab();

        var (name, _) = FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.Radio, 0, new PdfRect(200, 500, 214, 514), null));

        Assert.Equal("Radio1", name);
    }

    [Fact]
    public void ARadioGroupCanBeNamedWhenItIsMadeAndLaterButtonsJoinIt()
    {
        using var tab = FormPdfs.Tab();

        var (first, _) = FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.Radio, 0, new PdfRect(200, 500, 214, 514), null, " size "));
        var (second, widget) = FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.Radio, 0, new PdfRect(240, 500, 254, 514), null, "size"));

        Assert.Equal(("size", "size", 1), (first, second, widget));
        Assert.Equal(["Choice1", "Choice2"], FormPdfs.Read(tab).Find("size")!.Widgets.Select(w => w.OnState));
    }

    [Fact]
    public void AGroupNameWinsOverTheSelectedGroupAndCannotTakeAnotherKindsName()
    {
        using var tab = FormPdfs.Tab();

        var (name, _) = FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.Radio, 0, new PdfRect(200, 500, 214, 514), form.Find("plan"), "other"));

        Assert.Equal("other", name);
        Assert.Equal(2, FormPdfs.Read(tab).Find("plan")!.Widgets.Count);
        Assert.Throws<InvalidOperationException>(() => FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.Radio, 0, new PdfRect(200, 450, 214, 464), null, "name")));
    }

    [Theory]
    [InlineData("example.com/form", "https://example.com/form")]
    [InlineData(" http://example.com ", "http://example.com")]
    [InlineData("mailto:a@example.com", "mailto:a@example.com")]
    [InlineData("forms@acme.com", "mailto:forms@acme.com")]
    [InlineData("https://forms@acme.com", null)]
    [InlineData("two words", null)]
    [InlineData("", null)]
    [InlineData("javascript:alert(1)", null)]
    public void AddressesAreWebOrMailAddresses(string typed, string? expected)
    {
        Assert.Equal(expected, FormEdits.AddressOf(typed));
    }

    [Fact]
    public void ColoursAreComparedAsTheyShowOnScreen()
    {
        Assert.True(FormEdits.SameColour([0], [0, 0, 0]));
        Assert.True(FormEdits.SameColour([0.5], [0.5, 0.5, 0.5]));
        Assert.True(FormEdits.SameColour([0, 0, 0, 1], [0]));
        Assert.False(FormEdits.SameColour([0, 0, 1], [1, 0, 0]));
    }

    [Fact]
    public void LookAndActionAreOneUndoableStepEach()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Change font", form => { form.SetFont(form.Find("name")!, "CoBo"); return 0; });
        FormEdits.Apply(tab, Fonts, "Change button action", form =>
        {
            var go = form.AddField(new FieldSpec(FieldKind.PushButton, "go", 0, new PdfRect(300, 100, 400, 124)) { Caption = "Go" });
            form.SetButtonAction(go, new ButtonAction(ButtonActionKind.Hide, "name"));
            return 0;
        });

        var form = FormPdfs.Read(tab);
        Assert.Equal("CoBo", form.GetTextLook(form.Find("name")!).Font);
        Assert.Equal(new ButtonAction(ButtonActionKind.Hide, "name"), form.GetButtonAction(form.Find("go")!));
        tab.Undo();
        Assert.Null(FormPdfs.Read(tab).Find("go"));
        tab.Undo();
        Assert.Equal("Helv", FormPdfs.Read(tab).GetTextLook(FormPdfs.Read(tab).Find("name")!).Font);
    }

    [Fact]
    public void MovingAndResizingAWidgetKeepsItsField()
    {
        using var tab = FormPdfs.Tab();
        var rect = new PdfRect(70, 650, 400, 700);

        FormEdits.Apply(tab, Fonts, "Move form field", form => { form.Resize(form.Find("code")!.Widgets[0], rect); return true; });

        Assert.Equal(rect, FormPdfs.Read(tab).Find("code")!.Widgets[0].Rect);
    }

    [Fact]
    public void ATakenNameIsRefusedWithCoresSentenceAndNothingIsCommitted()
    {
        using var tab = FormPdfs.Tab();

        var error = Assert.Throws<InvalidOperationException>(() =>
            FormEdits.Apply(tab, Fonts, "Rename field", form => { form.Rename(form.Find("code")!, "name"); return true; }));

        Assert.Equal(FormText.NameTaken("name"), error.Message);
        Assert.Equal(FormText.NameTaken("name"), FormEdits.ProblemOf(error).Text);
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public void AFlagAndTheOptionsAreChangedThroughCore()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Change choices", form =>
        {
            form.SetFlag(form.Find("code")!, FieldFlags.Required, true);
            form.SetOptions(form.Find("city")!, FormEdits.ParseOptions("Ankara\nIZ=Izmir\n\n Bursa "));
            return true;
        });

        var read = FormPdfs.Read(tab);
        Assert.True(read.Find("code")!.Has(FieldFlags.Required));
        Assert.Equal([new FieldOption("Ankara"), new FieldOption("IZ", "Izmir"), new FieldOption("Bursa")], read.Find("city")!.Options);
    }

    [Fact]
    public void OptionsWriteBackAsTheyWereTyped()
    {
        var options = FormEdits.ParseOptions("Ankara\r\nIZ=Izmir");

        Assert.Equal("Ankara\r\nIZ=Izmir", FormEdits.FormatOptions(options));
    }

    [Fact]
    public void RemovingOneRadioButtonLeavesTheGroup()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Delete form field", form => { form.Remove(form.Find("plan")!.Widgets[1]); return true; });

        Assert.Single(FormPdfs.Read(tab).Find("plan")!.Widgets);
    }

    [Fact]
    public void TheTabOrderOfAPageIsSetAndRead()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Change tab order", form => { form.SetTabOrder(0, TabOrder.Row); return true; });

        Assert.Equal(TabOrder.Row, FormPdfs.Read(tab).GetTabOrder(0));
    }

    [Fact]
    public void FillingAStaticXfaFormRemovesTheXfaData()
    {
        using var tab = FormPdfs.Tab(FormPdfs.StaticXfa());
        Assert.Equal(XfaKind.Static, FormPdfs.Read(tab).Xfa);

        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("name", "Ada"));

        Assert.Equal(XfaKind.None, FormPdfs.Read(tab).Xfa);
    }

    [Fact]
    public void ADynamicXfaFormCannotBeFilledAndSaysWhy()
    {
        using var tab = FormPdfs.Tab(FormPdfs.DynamicXfa());
        Assert.Equal(XfaKind.Dynamic, FormPdfs.Read(tab).Xfa);

        var error = Assert.Throws<PdfReadException>(() => FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("name", "Ada")));

        Assert.Equal(FormText.DynamicXfa, FormEdits.ProblemOf(error).Text);
    }

    [Fact]
    public void DetectingReadsACopyAndLeavesTheTabAlone()
    {
        var bytes = PdfFromText.Create("Name: ______________________\nCity: ______________________", Fonts).Bytes;
        using var tab = FormPdfs.Tab(bytes);

        var found = FormEdits.Detect(tab);

        Assert.False(tab.IsDirty);
        Assert.NotEmpty(found);
        Assert.All(found, p => Assert.Equal(0, p.PageIndex));
    }

    [Fact]
    public void ARefusedEditLeavesNothingPendingInTheDocument()
    {
        using var tab = FormPdfs.Tab();

        Assert.Throws<InvalidOperationException>(() => FormEdits.Apply(tab, Fonts, "Rename field", form =>
        {
            form.SetFlag(form.Find("code")!, FieldFlags.Required, true);
            form.Rename(form.Find("code")!, "name");
            return true;
        }));

        Assert.False(tab.IsDirty);
        Assert.False(FormPdfs.Read(tab).Find("code")!.Has(FieldFlags.Required));
        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("name", "Ada"));
        tab.Undo();
        Assert.False(FormPdfs.Read(tab).Find("code")!.Has(FieldFlags.Required));
    }

    [Fact]
    public async Task AnEditCancelledWhileItRanIsNotCommitted()
    {
        using var tab = FormPdfs.Tab();
        using var source = new CancellationTokenSource();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => FormEdits.ApplyAsync(tab, Fonts, "Reset form", form =>
        {
            form.SetValue("name", "Ada");
            source.Cancel();
            return 1;
        }, source.Token));

        Assert.False(tab.IsDirty);
        Assert.Null(FormPdfs.Read(tab).Find("name")!.Value);
    }

    [Fact]
    public async Task AnEditWhoseDocumentWasReplacedMeanwhileSaysSoAndKeepsTheNewOne()
    {
        using var tab = FormPdfs.Tab();
        FormEdits.Apply(tab, Fonts, "Fill form field", form => form.SetValue("name", "Ada"));

        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => FormEdits.ApplyAsync(tab, Fonts, "Reset form", form =>
        {
            tab.Session.Undo();
            return form.Reset();
        }));

        Assert.Equal(Loc.T("The file changed meanwhile. Run it again."), error.Message);
        Assert.False(tab.Session.CanUndo);
        Assert.False(tab.IsDirty);
    }

    [Fact]
    public void AFieldDrawnOnATurnedPageIsTurnedWithIt()
    {
        using var tab = FormPdfs.Tab(FormPdfs.Turned());

        var (name, _) = FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.Text, 0, new PdfRect(300, 100, 320, 250), null));

        var mk = (PdfDictionary)tab.Document.Resolve(FormPdfs.Read(tab).Find(name)!.Widgets[0].Dictionary["MK"])!;
        Assert.Equal(90, tab.Document.Integer(mk, "R"));
    }

    [Fact]
    public void FoundFieldsTakeFreeNamesInsteadOfFailingHalfWay()
    {
        using var tab = FormPdfs.Tab();
        var found = new[]
        {
            new FieldProposal(0, new PdfRect(60, 300, 200, 320), FieldKind.Text, "fresh", null),
            new FieldProposal(0, new PdfRect(60, 270, 200, 290), FieldKind.Text, "name", null),
            new FieldProposal(0, new PdfRect(60, 240, 200, 260), FieldKind.Text, "name.first", null),
        };

        int added = FormEdits.Apply(tab, Fonts, "Add form fields", form => FormEdits.AddFound(form, found));

        var form = FormPdfs.Read(tab);
        Assert.Equal(3, added);
        Assert.NotNull(form.Find("fresh"));
        Assert.NotNull(form.Find("name_2"));
        Assert.NotNull(form.Find("name_first"));
    }

    [Fact]
    public void AButtonCaptionIsSetAndReadBack()
    {
        using var tab = FormPdfs.Tab();
        FormEdits.Apply(tab, Fonts, "Add form field", form => FormEdits.Add(form, FieldKind.PushButton, 0, new PdfRect(60, 300, 160, 324), null));

        FormEdits.Apply(tab, Fonts, "Change button caption", form => { FormEdits.SetCaption(form, form.Find("Button1")!, "Submit"); return true; });

        var form = FormPdfs.Read(tab);
        Assert.Equal("Submit", FormEdits.CaptionOf(form, form.Find("Button1")!));
    }

    [Fact]
    public void DuplicatingATextFieldKeepsItsLookUnderANewName()
    {
        using var tab = FormPdfs.Tab();
        FormEdits.Apply(tab, Fonts, "Add", form =>
        {
            var spec = new FieldSpec(FieldKind.Text, "note", 0, new PdfRect(60, 300, 200, 320))
            {
                Flags = FieldFlags.Required | FieldFlags.Multiline, Tooltip = "Say more", FontSize = 11, BorderColor = [1, 0, 0], Background = [1, 1, 0.5], BorderWidth = 2,
            };
            form.AddField(spec);
            return true;
        });

        var added = FormEdits.Apply(tab, Fonts, "Duplicate form fields", form =>
        {
            var field = form.Find("note")!;
            return FormEdits.Paste(form, [FormEdits.CopySpec(form, field, field.Widgets[0])], 0, true, 1);
        });

        var read = FormPdfs.Read(tab);
        var copy = read.Find("note_2")!;
        Assert.Equal([("note_2", 0)], added);
        Assert.Equal(read.Find("note")!.Flags, copy.Flags);
        Assert.Equal("Say more", copy.Tooltip);
        Assert.Equal(11, read.GetTextLook(copy).Size);
        var spec = FormEdits.CopySpec(read, copy, copy.Widgets[0]);
        Assert.Equal([1, 0, 0], spec.BorderColor!);
        Assert.Equal([1, 1, 0.5], spec.Background!);
        Assert.Equal(2, spec.BorderWidth);
        var old = read.Find("note")!.Widgets[0].Rect;
        Assert.Equal(old.Left + 12, copy.Widgets[0].Rect.Left, 3);
        Assert.Equal(old.Bottom - 12, copy.Widgets[0].Rect.Bottom, 3);
        Assert.Equal(old.Right - old.Left, copy.Widgets[0].Rect.Right - copy.Widgets[0].Rect.Left, 3);
        Assert.Equal("Duplicate form fields", tab.Session.UndoLabel);
        tab.Undo();
        Assert.Null(FormPdfs.Read(tab).Find("note_2"));
        Assert.NotNull(FormPdfs.Read(tab).Find("note"));
    }

    [Fact]
    public void ACopiedRadioButtonJoinsItsGroup()
    {
        using var tab = FormPdfs.Tab();

        FormEdits.Apply(tab, Fonts, "Paste form fields", form =>
        {
            var plan = form.Find("plan")!;
            return FormEdits.Paste(form, [FormEdits.CopySpec(form, plan, plan.Widgets[0])], 0, false, 1);
        });

        var read = FormPdfs.Read(tab);
        Assert.Equal(3, read.Find("plan")!.Widgets.Count);
        Assert.Null(read.Find("plan_2"));
    }

    [Fact]
    public void APastedRadioGroupKeepsItsButtonValues()
    {
        using var tab = FormPdfs.Tab();
        FormEdits.Apply(tab, Fonts, "Rename buttons", f =>
        {
            var widgets = f.Find("plan")!.Widgets;
            f.SetExportValue(widgets[0], "Basic");
            f.SetExportValue(widgets[1], "Pro");
            return true;
        });
        var form = FormPdfs.Read(tab);
        var plan = form.Find("plan")!;
        var specs = plan.Widgets.Select(w => FormEdits.CopySpec(form, plan, w) with { Name = "tier" }).ToList();
        var states = plan.Widgets.Select(w => w.OnState).ToList();

        FormEdits.Apply(tab, Fonts, "Paste form fields", f => FormEdits.Paste(f, specs, 0, false, 1));

        Assert.Equal(states, FormPdfs.Read(tab).Find("tier")!.Widgets.Select(w => w.OnState));
    }

    [Fact]
    public void PastingAgainStepsFurtherAndStaysOnThePage()
    {
        using var tab = FormPdfs.Tab();
        var form = FormPdfs.Read(tab);
        var specs = new[] { FormEdits.CopySpec(form, form.Find("code")!, form.Find("code")!.Widgets[0]) };

        FormEdits.Apply(tab, Fonts, "Paste form fields", f => FormEdits.Paste(f, specs, 1, false, 2));
        FormEdits.Apply(tab, Fonts, "Paste form fields", f => FormEdits.Paste(f, specs, 1, false, 100000));

        var read = FormPdfs.Read(tab);
        var first = read.Find("code_2")!.Widgets[0];
        Assert.Equal(1, first.PageIndex);
        Assert.Equal(specs[0].Rect.Left + 24, first.Rect.Left, 3);
        var crop = read.Document.Pages[1].CropBox;
        Assert.Equal(crop.Right, read.Find("code_3")!.Widgets[0].Rect.Right, 3);
        Assert.Equal(crop.Bottom, read.Find("code_3")!.Widgets[0].Rect.Bottom, 3);
    }

    [Fact]
    public void ChangingFieldsNeedsPermissionToModifyTheFile()
    {
        using var tab = FormPdfs.Tab();

        Assert.True(FormEdits.CanModify(tab.Document));
    }

    [Fact]
    public void AFormWithoutFieldsReadsAsEmpty()
    {
        using var tab = FormPdfs.Tab(Pdfs.Text());

        Assert.Empty(FormPdfs.Read(tab).Fields);
        Assert.Equal(XfaKind.None, FormPdfs.Read(tab).Xfa);
    }

    [Fact]
    public void ChangingOneFieldAgainJoinsTheStep()
    {
        using var tab = FormPdfs.Tab();
        var fills = new FillMerge();

        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("name", "A"));
        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("name", "Ada"));

        Assert.Equal("Ada", FormPdfs.Read(tab).Find("name")!.Value);
        tab.Undo();
        Assert.Null(FormPdfs.Read(tab).Find("name")!.Value);
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public void SeveralFieldsAreOneStep()
    {
        using var tab = FormPdfs.Tab();
        var fills = new FillMerge();

        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("name", "Ada"));
        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("code", "12"));
        Assert.Equal("Fill form", tab.Session.UndoLabel);
        tab.Undo();

        Assert.Null(FormPdfs.Read(tab).Find("name")!.Value);
        Assert.Null(FormPdfs.Read(tab).Find("code")!.Value);
        Assert.False(tab.Session.CanUndo);
    }

    [Fact]
    public void AnUndoOrAnotherToolStartsANewStep()
    {
        using var tab = FormPdfs.Tab();
        var fills = new FillMerge();
        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("name", "A"));
        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("name", "Ad"));
        FormEdits.Apply(tab, Fonts, "Change tab order", form => { form.SetTabOrder(0, TabOrder.Row); return true; });

        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("name", "Ada"));
        tab.Undo();
        Assert.Equal("Ad", FormPdfs.Read(tab).Find("name")!.Value);

        fills.Apply(tab, Fonts, "Fill form", form => form.SetValue("name", "Adam"));
        tab.Undo();
        Assert.Equal("Ad", FormPdfs.Read(tab).Find("name")!.Value);
    }
}
