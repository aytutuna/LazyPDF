using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FormFillTests
{
    private static PdfForm Open(string acroEntries = "", IFontSource? fonts = null) =>
        PdfForm.Read(FormFixtures.Open(acroEntries), fonts);

    private static FormWidget Widget(PdfForm form, string name, int index = 0) => form.Find(name)!.Widgets[index];

    private static PdfStream Normal(PdfForm form, FormWidget widget) =>
        (PdfStream)form.Document.Resolve(form.Document.Dict(widget.Dictionary, "AP")!["N"])!;

    private static string[] Operators(IReadOnlyList<ContentOperation> operations) => [.. operations.Select(o => o.Operator)];

    private static double[] Numbers(PdfForm form, PdfDictionary d, string key) =>
        [.. form.Document.Array(d, key)!.Items.Select(i => ((PdfNumber)i).Value)];

    [Fact]
    public void TextValueGetsAnAppearanceInTheFormsOwnFont()
    {
        var form = Open();

        var result = form.SetValue("name", "Ada Lovelace");

        Assert.Equal(1, result.Filled);
        Assert.Equal("Ada Lovelace", form.Find("name")!.Value);
        Assert.Equal("Ada Lovelace", FormFixtures.Drawn(form.Document, Widget(form, "name")));
        var stream = Normal(form, Widget(form, "name"));
        Assert.Equal([0.0, 0.0, 200.0, 20.0], Numbers(form, stream.Dictionary, "BBox"));
        var operators = Operators(ContentParser.Parse(form.Document.Data(stream)));
        Assert.Contains("BMC", operators);
        Assert.Contains("Tj", operators);
        Assert.Contains("0 0 1 rg", System.Text.Encoding.Latin1.GetString(form.Document.Data(stream)));
        var used = form.Document.Dict(form.Document.Dict(stream.Dictionary, "Resources"), "Font")!.Entries.Single().Value;
        Assert.Equal(form.Document.Dict(form.Document.Dict(form.AcroForm, "DR"), "Font")!["Helv"], used);
        Assert.Equal("Ada Lovelace", PdfForm.Read(Reopen(form.Document)).Find("name")!.Value);
    }

    [Fact]
    public void ClearingAValueRemovesItButKeepsTheFrame()
    {
        var form = Open();
        form.SetValue("name", "x");

        form.SetValue("name", null);

        Assert.Null(form.Find("name")!.Value);
        Assert.NotNull(form.Document.Dict(Widget(form, "name").Dictionary, "AP"));
        Assert.Equal("", FormFixtures.Drawn(form.Document, Widget(form, "name")));
    }

    [Fact]
    public void TurkishTextUsesAnAddedFontAndTheDefaultAppearanceFollowsIt()
    {
        var form = Open(fonts: new ArialSource());

        form.SetValue("name", "Şükrü ığ İĞ");

        var field = form.Find("name")!;
        Assert.Equal("Şükrü ığ İĞ", field.Value);
        Assert.Equal("Şükrü ığ İĞ", FormFixtures.Drawn(form.Document, field.Widgets[0]));
        Assert.StartsWith("/LzF1 12 Tf", field.DefaultAppearance);
        var fonts = form.Document.Dict(form.Document.Dict(form.AcroForm, "DR"), "Font")!;
        Assert.True(fonts.ContainsKey("LzF1"));
        Assert.True(fonts.ContainsKey("Helv"));
        var embedded = (PdfDictionary)form.Document.Resolve(fonts["LzF1"])!;
        Assert.Equal("Type0", form.Document.Name(embedded, "Subtype"));
        Reopen(form.Document);
    }

    [Fact]
    public void FontNameWithReplacementSyntaxGoesIntoTheDefaultAppearanceLiterally()
    {
        var form = Open();
        var holder = new PdfDictionary();

        PdfForm.SetFontName(holder, "/Helv 12 Tf 0 g", "A$1B");

        Assert.Equal("/A$1B 12 Tf 0 g", PdfText.Read(form.Document, holder, "DA"));
    }

    [Fact]
    public void FieldsOfOneBatchShareOneAddedFont()
    {
        var form = Open(fonts: new ArialSource());

        form.SetValues([new("name", "Çağrı"), new("bio", "Ömür boyu")]);

        var fonts = form.Document.Dict(form.Document.Dict(form.AcroForm, "DR"), "Font")!;
        Assert.Equal(2, fonts.Entries.Count);
        Assert.Equal(form.Find("name")!.DefaultAppearance!.Split(' ')[0], form.Find("bio")!.DefaultAppearance!.Split(' ')[0]);
    }

    [Fact]
    public void TurkishTextWithoutAFontSourceChangesNothing()
    {
        var form = Open();

        var thrown = Assert.Throws<InvalidOperationException>(() => form.SetValue("name", "ğüş"));

        Assert.Equal(FormText.NoFont, thrown.Message);
        Assert.Null(form.Find("name")!.Value);
    }

    [Fact]
    public void CheckBoxTakesExportValuesAndWords()
    {
        var form = Open();

        form.SetValue("agree", "Yes");
        Assert.True(form.Find("agree")!.IsChecked);
        Assert.Equal("Yes", form.Document.Name(Widget(form, "agree").Dictionary, "AS"));

        form.SetValue("agree", "no");
        Assert.False(form.Find("agree")!.IsChecked);
        Assert.Equal("Off", form.Document.Name(Widget(form, "agree").Dictionary, "AS"));

        form.SetValue("agree", "on");
        Assert.True(form.Find("agree")!.IsChecked);
        Assert.Contains("agree", form.SetValue("agree", "maybe").Rejected);
    }

    [Fact]
    public void RadioGroupMovesTheChoiceAndRejectsUnknownOnes()
    {
        var form = Open();

        form.SetValue("choice", "b");
        var choice = form.Find("choice")!;
        Assert.Equal("b", choice.Value);
        Assert.Equal(["Off", "b"], choice.Widgets.Select(w => form.Document.Name(w.Dictionary, "AS")));
        Assert.Equal("b", form.Document.Name(choice.Dictionary, "V"));

        form.SetValue("choice", "a");
        Assert.Equal(["a", "Off"], form.Find("choice")!.Widgets.Select(w => form.Document.Name(w.Dictionary, "AS")));

        var result = form.SetValue("choice", "zzz");
        Assert.Equal(["choice"], result.Rejected);
        Assert.Equal("a", form.Find("choice")!.Value);
    }

    [Fact]
    public void RadioExportsComeFromOpt()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [11 0 R 12 0 R]>>");
        pdf.Obj(10, "<</T (size) /FT /Btn /Ff 32768 /Opt [(Small) (Large)] /Kids [11 0 R 12 0 R]>>");
        pdf.Obj(11, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [0 0 14 14] /P 3 0 R /AS /Off /AP <</N <</0 20 0 R /Off 20 0 R>>>>>>");
        pdf.Obj(12, "<</Type /Annot /Subtype /Widget /Parent 10 0 R /Rect [30 0 44 14] /P 3 0 R /AS /Off /AP <</N <</1 20 0 R /Off 20 0 R>>>>>>");
        pdf.Stream(20, "/Type /XObject /Subtype /Form /BBox [0 0 14 14]", "");
        var form = PdfForm.Read(PdfDocument.Open(pdf.Finish()));

        form.SetValue("size", "Large");

        var field = form.Find("size")!;
        Assert.Equal("Large", field.Value);
        Assert.Equal("1", form.Document.Name(field.Dictionary, "V"));
        Assert.Equal(["Off", "1"], field.Widgets.Select(w => form.Document.Name(w.Dictionary, "AS")));
    }

    [Fact]
    public void ComboTakesDisplayTextAndStoresTheExport()
    {
        var form = Open();

        form.SetValue("city", "Izmir");

        Assert.Equal("IZ", form.Find("city")!.Value);
        Assert.Equal("Izmir", FormFixtures.Drawn(form.Document, Widget(form, "city")));
        Assert.Contains("city", form.SetValue("city", "Nowhere").Rejected);
    }

    [Fact]
    public void EditableComboTakesAnyText()
    {
        var form = Open();
        form.SetFlag(form.Find("city")!, FieldFlags.Edit, true);

        form.SetValue("city", "Nowhere");

        Assert.Equal("Nowhere", form.Find("city")!.Value);
    }

    [Fact]
    public void MultiSelectListStoresValuesAndIndexes()
    {
        var form = Open();

        form.SetValue("langs", "English; German");

        var langs = form.Find("langs")!;
        Assert.Equal(["English", "German"], langs.Selected);
        Assert.Equal([1.0, 2.0], Numbers(form, langs.Dictionary, "I"));
        Assert.StartsWith("TurkishEnglishGerman", FormFixtures.Drawn(form.Document, langs.Widgets[0]));
    }

    [Fact]
    public void ListScrollsToKeepTheSelectionVisible()
    {
        var form = Open();

        form.SetValue("langs", "Latin");

        var langs = form.Find("langs")!;
        Assert.True((form.Document.Number(langs.Dictionary, "TI") ?? 0) > 0);
        string drawn = FormFixtures.Drawn(form.Document, langs.Widgets[0]);
        Assert.EndsWith("Latin", drawn);
        Assert.DoesNotContain("Turkish", drawn);
    }

    [Fact]
    public void CombFieldCutsAtMaxLengthAndSpacesTheCharacters()
    {
        var form = Open();

        form.SetValue("code", "1234567");

        Assert.Equal("123456", form.Find("code")!.Value);
        var recorder = new GlyphBoxes();
        new ContentInterpreter(form.Document).Run(Normal(form, Widget(form, "code")), recorder);
        Assert.Equal(6, recorder.Lefts.Count);
        Assert.InRange(recorder.Lefts[1] - recorder.Lefts[0], 19, 21);
    }

    [Fact]
    public void PasswordFieldDrawsBullets()
    {
        var form = Open();

        form.SetValue("secret", "abc");

        Assert.Equal("abc", form.Find("secret")!.Value);
        Assert.Equal("•••", FormFixtures.Drawn(form.Document, Widget(form, "secret")));
    }

    [Fact]
    public void MultilineTextWrapsAtTheFieldWidth()
    {
        var form = Open();

        form.SetValue("bio", "one two three four five six seven eight nine ten eleven twelve thirteen\nsecond paragraph");

        var stream = Normal(form, Widget(form, "bio"));
        int lines = ContentParser.Parse(form.Document.Data(stream)).Count(o => o.Operator == "Tj");
        Assert.True(lines >= 3, $"{lines} lines");
        Assert.EndsWith("second paragraph", FormFixtures.Drawn(form.Document, Widget(form, "bio")));
    }

    [Fact]
    public void FieldsSharingANameChangeTogether()
    {
        var form = TwoTextFields("/T (same) /DV (x)", "/T (same)");

        var result = form.SetValue("same", "both");

        Assert.Equal(2, result.Filled);
        Assert.All(form.FindAll("same"), f => Assert.Equal("both", f.Value));
        Assert.All(form.FindAll("same"), f => Assert.Equal("both", FormFixtures.Drawn(form.Document, f.Widgets[0])));
    }

    [Fact]
    public void UnknownNamesAndButtonsAreReported()
    {
        var form = Open();

        var result = form.SetValues([new("nothing", "x"), new("sig", "x"), new("name", "ok")]);

        Assert.Equal(["nothing"], result.UnknownFields);
        Assert.Equal(["sig"], result.Rejected);
        Assert.Equal(1, result.Filled);
    }

    [Fact]
    public void ResetReturnsFieldsToTheirDefaults()
    {
        var form = TwoTextFields("/T (a) /DV (start) /V (start)", "/T (b) /V (leftover)");
        form.SetValue("a", "changed");

        Assert.Equal(2, form.Reset());

        Assert.Equal("start", form.Find("a")!.Value);
        Assert.Null(form.Find("b")!.Value);
        Assert.Equal("start", FormFixtures.Drawn(form.Document, form.Find("a")!.Widgets[0]));
    }

    [Fact]
    public void ResetClearsCheckBoxesAndRadios()
    {
        var form = Open();
        form.SetValues([new("agree", "Yes"), new("choice", "a")]);

        form.Reset();

        Assert.False(form.Find("agree")!.IsChecked);
        Assert.Equal("Off", form.Find("choice")!.Value);
        Assert.Equal(["Off", "Off"], form.Find("choice")!.Widgets.Select(w => form.Document.Name(w.Dictionary, "AS")));
    }

    [Fact]
    public void RotatedWidgetsGetAMatrixThatTurnsTheDrawing()
    {
        var form = TwoTextFields("/T (r) /Rect [0 0 20 100] /MK <</R 90>>", "/T (s)");

        form.SetValue("r", "turned");

        var stream = Normal(form, form.Find("r")!.Widgets[0]);
        Assert.Equal([0.0, 0.0, 100.0, 20.0], Numbers(form, stream.Dictionary, "BBox"));
        Assert.Equal([0.0, 1.0, -1.0, 0.0, 20.0, 0.0], Numbers(form, stream.Dictionary, "Matrix"));
    }

    [Fact]
    public void RegenerateRedrawsEveryFieldFromItsValue()
    {
        var form = Open();
        form.Find("name")!.Dictionary["V"] = PdfText.ToObject("typed elsewhere");
        form.Refresh();

        form.Regenerate();

        Assert.Equal("typed elsewhere", FormFixtures.Drawn(form.Document, Widget(form, "name")));
    }

    [Fact]
    public void StaticXfaIsDroppedAndDynamicIsRefused()
    {
        var form = Open("/XFA [(template) 12 0 R]");
        Assert.Equal(XfaKind.Static, form.Xfa);

        form.SetValue("name", "x");

        Assert.True(form.XfaRemoved);
        Assert.False(form.Document.HasXfa);

        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 12 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");
        var dynamic = PdfForm.Read(PdfDocument.Open(pdf.Finish()));
        Assert.Equal(XfaKind.Dynamic, dynamic.Xfa);
        Assert.Equal(PdfReadProblem.Unsupported, Assert.Throws<PdfReadException>(() => dynamic.SetValue("x", "y")).Problem);
        Assert.Throws<PdfReadException>(() => dynamic.Reset());
    }

    // Two text fields on one page in a form with Helvetica as Helv; each argument is the rest of a widget dictionary.
    internal static PdfForm TwoTextFields(string first, string second)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [10 0 R 11 0 R] /DA (/Helv 10 Tf 0 g) /DR <</Font <</Helv 12 0 R>>>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R]>>");
        pdf.Obj(10, $"<</Type /Annot /Subtype /Widget /FT /Tx /Rect [0 0 100 20] /P 3 0 R {first}>>");
        pdf.Obj(11, $"<</Type /Annot /Subtype /Widget /FT /Tx /Rect [0 40 100 60] /P 3 0 R {second}>>");
        pdf.Obj(12, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        return PdfForm.Read(PdfDocument.Open(pdf.Finish()));
    }

    private sealed class GlyphBoxes : ContentVisitor
    {
        public List<double> Lefts { get; } = [];

        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => Lefts.Add(glyph.Bounds.Left);
    }
}
