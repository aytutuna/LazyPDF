using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class FormScriptTests
{
    // Text fields a, b and total on one page; the arguments are the extra keys of each.
    private static PdfForm Build(string a = "", string b = "", string total = "", string acro = "", string catalog = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog} /AcroForm <</Fields [10 0 R 11 0 R 12 0 R] /DA (/Helv 10 Tf 0 g) /DR <</Font <</Helv 20 0 R>>>> {acro}>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [10 0 R 11 0 R 12 0 R]>>");
        pdf.Obj(10, $"<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [0 0 100 20] /P 3 0 R {a}>>");
        pdf.Obj(11, $"<</Type /Annot /Subtype /Widget /FT /Tx /T (b) /Rect [0 40 100 60] /P 3 0 R {b}>>");
        pdf.Obj(12, $"<</Type /Annot /Subtype /Widget /FT /Tx /T (total) /Rect [0 80 100 100] /P 3 0 R {total}>>");
        pdf.Obj(20, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>");
        return PdfForm.Read(PdfDocument.Open(pdf.Finish()));
    }

    private static string Js(string event_, string source) => $"/AA <</{event_} <</S /JavaScript /JS ({source})>>>>";

    private static FormCall Call(string source) => FormScriptParser.Parse(source)![0];

    [Theory]
    [InlineData("AFNumber_Format(2, 0, 0, 0, \"$\", true);")]
    [InlineData("AFNumber_Format(2,0,0,0,'',true)")]
    [InlineData("// totals\nAFSimple_Calculate(\"SUM\", new Array(\"a\", \"b\"));")]
    [InlineData("AFDate_FormatEx(\"dd/mm/yyyy\"); AFRange_Validate(true, 0, false, 0)")]
    [InlineData("AFSimple_Calculate('AVG', ['a','b'])")]
    public void BuiltInCallsAreUnderstood(string source) => Assert.NotNull(FormScriptParser.Parse(source));

    [Theory]
    [InlineData("event.value = 1;")]
    [InlineData("AFNumber_Format(2, 0, 0, 0, \"$\", true); app.alert(1);")]
    [InlineData("AFNumber_Format(x);")]
    [InlineData("AFNumber_Format(2, 0")]
    [InlineData("AFUnknown_Format(2);")]
    [InlineData("")]
    public void AnythingElseIsLeftAlone(string source) => Assert.Null(FormScriptParser.Parse(source));

    [Fact]
    public void ArgumentsKeepTheirTypes()
    {
        var call = Call("AFNumber_Format(2, -1, 3.5, 0, 'A\\'s', false)");

        Assert.Equal("AFNumber_Format", call.Name);
        Assert.Equal(2, call.Number(0));
        Assert.Equal(-1, call.Number(1));
        Assert.Equal(3.5, call.Number(2));
        Assert.Equal("A's", call.Text(4));
        Assert.False(call.Flag(5, true));
    }

    [Theory]
    [InlineData("AFNumber_Format(2, 0, 0, 0, \"\", true)", "1234.5", "1,234.50")]
    [InlineData("AFNumber_Format(0, 1, 0, 0, \"\", true)", "1234.5", "1235")]
    [InlineData("AFNumber_Format(2, 2, 0, 0, \"\", true)", "1234.5", "1.234,50")]
    [InlineData("AFNumber_Format(2, 3, 0, 0, \"\", true)", "1234,5", "1234,50")]
    [InlineData("AFNumber_Format(2, 0, 0, 0, \" TL\", false)", "10", "10.00 TL")]
    [InlineData("AFNumber_Format(2, 0, 0, 0, \"$\", true)", "-3", "-$3.00")]
    [InlineData("AFNumber_Format(2, 0, 2, 0, \"\", true)", "-3", "(3.00)")]
    [InlineData("AFPercent_Format(1, 0)", "0.256", "25.6%")]
    [InlineData("AFDate_FormatEx(\"dd/mm/yyyy\")", "2024-03-05", "05/03/2024")]
    [InlineData("AFDate_FormatEx(\"mmmm d, yyyy\")", "3/5/2024", "March 5, 2024")]
    [InlineData("AFDate_Format(2)", "2024-03-05", "03/05/24")]
    [InlineData("AFTime_Format(1)", "13:05", "1:05 pm")]
    [InlineData("AFTime_FormatEx(\"HH:MM:ss\")", "9:05:07 am", "09:05:07")]
    [InlineData("AFSpecial_Format(0)", "34000", "34000")]
    [InlineData("AFSpecial_Format(1)", "340001234", "34000-1234")]
    [InlineData("AFSpecial_Format(2)", "5551234567", "(555) 123-4567")]
    [InlineData("AFSpecial_Format(3)", "123456789", "123-45-6789")]
    public void FormatsShowTheValueTheWayAcrobatDoes(string call, string value, string shown) =>
        Assert.Equal(shown, FormFunctions.Format(Call(call), value)?.Text);

    [Fact]
    public void ValuesThatDoNotFitTheFormatAreShownAsTheyAre()
    {
        Assert.Null(FormFunctions.Format(Call("AFNumber_Format(2, 0, 0, 0, \"\", true)"), "abc"));
        Assert.Null(FormFunctions.Format(Call("AFDate_Format(1)"), "not a date"));
        Assert.Null(FormFunctions.Format(Call("AFSpecial_Format(0)"), "123"));
        Assert.Null(FormFunctions.Format(Call("AFNumber_Format(2, 0, 0, 0, \"\", true)"), ""));
        Assert.Equal<double[]?>([1.0, 0.0, 0.0], FormFunctions.Format(Call("AFNumber_Format(2, 0, 1, 0, \"\", true)"), "-1")!.Value.Color);
    }

    [Theory]
    [InlineData("1,234.56", 1234.56)]
    [InlineData("1.234,56", 1234.56)]
    [InlineData("1234,5", 1234.5)]
    [InlineData("$ 12", 12)]
    [InlineData("(7.5)", -7.5)]
    [InlineData("12%", 12)]
    [InlineData("1'234.5", 1234.5)]
    [InlineData("-.5", -0.5)]
    public void NumbersParseWhicheverWayTheyWereWritten(string text, double expected) =>
        Assert.Equal(expected, FormFunctions.ParseNumber(text));

    [Theory]
    [InlineData("12abc")]
    [InlineData("")]
    [InlineData("text")]
    public void NonNumbersDoNotParse(string text) => Assert.Null(FormFunctions.ParseNumber(text));

    [Theory]
    [InlineData("SUM", "10")]
    [InlineData("AVG", "3.3333333333")]
    [InlineData("PRD", "30")]
    [InlineData("MIN", "2")]
    [InlineData("MAX", "5")]
    public void SimpleCalculationsOverNamedFields(string function, string expected)
    {
        var call = Call($"AFSimple_Calculate(\"{function}\", new Array(\"a\", \"b\", \"c\"))");
        string?[] values = ["3", "5", "2"];

        Assert.Equal(expected, FormFunctions.Calculate(call, name => [values["abc".IndexOf(name[0])]]));
    }

    [Fact]
    public void RangeAndKeystrokeChecksSayWhatIsWrong()
    {
        Assert.Null(FormFunctions.Check(Call("AFRange_Validate(true, 0, true, 100)"), "50"));
        Assert.Equal(FormText.OutOfRange("0", "100"), FormFunctions.Check(Call("AFRange_Validate(true, 0, true, 100)"), "101"));
        Assert.Equal(FormText.AtLeast("0"), FormFunctions.Check(Call("AFRange_Validate(true, 0, false, 0)"), "-1"));
        Assert.Equal(FormText.AtMost("9"), FormFunctions.Check(Call("AFRange_Validate(false, 0, true, 9)"), "10"));
        Assert.Equal(FormText.BadNumber, FormFunctions.Check(Call("AFNumber_Keystroke(2, 0, 0, 0, \"\", true)"), "x1y"));
        Assert.Equal(FormText.BadDate, FormFunctions.Check(Call("AFDate_KeystrokeEx(\"dd/mm/yyyy\")"), "soon"));
        Assert.Equal(FormText.BadFormat, FormFunctions.Check(Call("AFSpecial_KeystrokeEx(\"AA-999\")"), "A1-234"));
        Assert.Null(FormFunctions.Check(Call("AFSpecial_KeystrokeEx(\"AA-999\")"), "AB-234"));
    }

    [Fact]
    public void FormatScriptChangesWhatTheAppearanceShowsNotTheValue()
    {
        var form = Build(a: Js("F", "AFNumber_Format(2, 0, 3, 0, \\\"\\\", true);"));

        form.SetValue("a", "-1234.5");

        Assert.Equal("-1234.5", form.Find("a")!.Value);
        Assert.Equal("(1,234.50)", FormFixtures.Drawn(form.Document, form.Find("a")!.Widgets[0]));
        Assert.Equal("(1,234.50)", form.DisplayText(form.Find("a")!));
        var stream = (PdfStream)form.Document.Resolve(form.Document.Dict(form.Find("a")!.Widgets[0].Dictionary, "AP")!["N"])!;
        Assert.Contains("1 0 0 rg", System.Text.Encoding.Latin1.GetString(form.Document.Data(stream)));
    }

    [Fact]
    public void CalculationOrderRunsSumsAndTheirDependents()
    {
        var form = Build(
            total: Js("C", "AFSimple_Calculate(\\\"SUM\\\", new Array(\\\"a\\\", \\\"b\\\"));") + " /DV (0)",
            acro: "/CO [12 0 R]");

        var result = form.SetValues([new("a", "2"), new("b", "3.5")]);

        Assert.Equal(1, result.Calculated);
        Assert.Empty(result.NotRun);
        Assert.Equal("5.5", form.Find("total")!.Value);
        Assert.Equal("5.5", FormFixtures.Drawn(form.Document, form.Find("total")!.Widgets[0]));
        Assert.Equal(["total"], form.CalculationOrder.Select(f => f.Name));
        form.SetValue("a", "10");
        Assert.Equal("13.5", form.Find("total")!.Value);
    }

    [Fact]
    public void CustomJavaScriptIsListedAndNeverRun()
    {
        var form = Build(
            total: Js("C", "event.value = this.getField(\\\"a\\\").value * 2;"),
            a: Js("K", "AFNumber_Keystroke(2, 0, 0, 0, \\\"\\\", true);") + " /A <</S /JavaScript /JS (app.alert\\(1\\);)>>",
            acro: "/CO [12 0 R]",
            catalog: "/Names <</JavaScript <</Names [(init) <</S /JavaScript /JS (var x = 1;)>>]>>>>");

        var result = form.SetValue("a", "7");

        var skipped = Assert.Single(result.NotRun);
        Assert.Equal("total", skipped.Field);
        Assert.False(skipped.BuiltIn);
        Assert.False(skipped.Ran);
        Assert.Null(form.Find("total")!.Value);
        var scripts = form.Scripts;
        Assert.Equal(4, scripts.Count);
        Assert.Contains(scripts, s => s.Event == "K" && s.BuiltIn && s.Ran);
        Assert.Contains(scripts, s => s.Event == "A" && !s.BuiltIn && !s.Ran);
        Assert.Contains(scripts, s => s.Field is null && s.Event == "Names/init" && !s.Ran);
        Assert.Contains(scripts, s => s.Event == "C" && s.Source.Contains("getField"));
        Assert.False(string.IsNullOrEmpty(FormText.ScriptNotRun));
    }

    [Fact]
    public void ValidateAppliesKeystrokeAndRangeScripts()
    {
        var form = Build(a: Js("V", "AFRange_Validate(true, 0, true, 100);"), b: Js("K", "AFNumber_Keystroke(0, 0, 0, 0, \\\"\\\", true);"));

        Assert.Null(form.Validate(form.Find("a")!, "50"));
        Assert.Equal(FormText.OutOfRange("0", "100"), form.Validate(form.Find("a")!, "500"));
        Assert.Equal(FormText.BadNumber, form.Validate(form.Find("b")!, "x"));
        Assert.Null(form.Validate(form.Find("total")!, "anything"));
    }
}
