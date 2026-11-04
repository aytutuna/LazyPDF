using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// A form starts from the state of the Do that paints it, with the names it inherits read in its own resources.
public class FormStateTests
{
    private static readonly RgbColor Red = new(255, 0, 0), Green = new(0, 255, 0), Blue = new(0, 0, 255);

    private static PdfEditSession Open(string page, string form, string formResources, string pageResources = "") =>
        EditKit.Session(page, more: pdf => pdf.Stream(7, $"/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <<{formResources}>>", form),
            resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>> " + pageResources);

    private static string FormData(PdfEditSession session)
    {
        var document = PdfDocument.Open(session.Current.ToArray());
        var forms = document.Dict(document.Pages[0].Resources, "XObject")!;
        return Encoding.Latin1.GetString(document.Data((PdfStream)document.Resolve(forms["Fm0"])!, 1 << 20));
    }

    [Fact]
    public void ARestoreInTheSecondPaintingOfAFormUsesTheStateOfThatPainting()
    {
        var session = Open("1 0 0 rg /Fm0 Do 0 0 1 rg 1 0 0 1 0 -100 cm /Fm0 Do", "BT /F1 12 Tf 50 700 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>");
        var second = TextSearch.Find(TextPage.Create(session.Document, session.Document.Pages[0]), "Hello", new TextSearchOptions(MatchCase: true))[1];
        var result = new PageEditor(session, 0).SetTextStyle([second.Range], new TextStyleChange(Color: Green));
        Assert.True(result.Done, result.Problem);
        var shown = EditKit.Shown(session);
        Assert.All(shown.Take(11).Where(g => g.Text != " "), g => Assert.Equal(Red, g.Color));
        var later = shown.Skip(11).ToList();
        Assert.All(EditKit.Of(later, "Hello"), g => Assert.Equal(Green, g.Color));
        Assert.All(EditKit.Of(later, "World"), g => Assert.Equal(Blue, g.Color));
    }

    [Fact]
    public void AFontNamedInTheCallerIsNotInheritedByAFormWithResourcesOfItsOwn()
    {
        var session = Open("BT /F1 12 Tf ET /Fm0 Do", "BT 50 700 Td (Hello World) Tj ET", "/Font <</F9 5 0 R>>");
        string before = FormData(session);
        var result = new PageEditor(session, 0).SetTextStyle([EditKit.Find(session, "Hello")], new TextStyleChange(Size: 20));
        Assert.False(result.Done);
        Assert.Equal(EditingText.FontSetOutside, result.Problem);
        Assert.Equal(before, FormData(session));
    }

    [Fact]
    public void AColourSpaceNamedInTheCallerCannotBeRestoredInAFormThatLacksIt()
    {
        const string Spot = "/ColorSpace <</Cs1 [/Separation /Spot /DeviceRGB <</FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [1 0 0] /N 1>>]>>";
        var session = Open("/Cs1 cs 1 sc /Fm0 Do", "BT /F1 12 Tf 50 700 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>", Spot);
        string before = FormData(session);
        var result = new PageEditor(session, 0).SetTextStyle([EditKit.Find(session, "Hello")], new TextStyleChange(Color: Blue));
        Assert.False(result.Done);
        Assert.Equal(EditingText.ColorOutside, result.Problem);
        Assert.Equal(before, FormData(session));
    }

    [Fact]
    public void ANameThatMeansTheSameInTheFormIsStillInherited()
    {
        var session = Open("BT /F1 12 Tf ET /Fm0 Do", "BT 50 700 Td (Hello World) Tj ET", "/Font <</F1 5 0 R>>");
        var result = new PageEditor(session, 0).SetTextStyle([EditKit.Find(session, "Hello")], new TextStyleChange(Size: 20));
        Assert.True(result.Done, result.Problem);
        var shown = EditKit.Shown(session);
        Assert.All(EditKit.Of(shown, "Hello"), g => Assert.Equal(20, g.Size));
        Assert.All(EditKit.Of(shown, "World"), g => Assert.Equal(12, g.Size));
    }

    [Fact]
    public void AParagraphLineInAFontThatCannotBeRestoredInTheFormIsRefused()
    {
        var session = Open("BT /F1 12 Tf ET /Fm0 Do",
            "BT 50 686 Td (second line) Tj 0 -300 Td (far text) Tj ET BT /F9 12 Tf 50 700 Td (first line) Tj ET", "/Font <</F9 6 0 R>>");
        string before = FormData(session);
        var editor = new PageEditor(session, 0);
        var block = editor.Objects.OfType<TextObject>().Single(o => o.Lines.Count == 2);
        var result = editor.ReplaceParagraph(block, "alpha\nbeta");
        Assert.False(result.Done);
        Assert.Equal(EditingText.FontSetOutside, result.Problem);
        Assert.Equal(before, FormData(session));
    }

    [Fact]
    public void ATransparencyGroupDoesNotInheritTheGraphicsStateOfTheCaller()
    {
        var session = EditKit.Session("/GS0 gs /Fm0 Do",
            more: pdf =>
            {
                pdf.Obj(8, "<</Type /ExtGState /ca 0.5>>");
                pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Group <</S /Transparency>> /Resources <</Font <</F1 5 0 R>> /ExtGState <</GS0 8 0 R>>>>",
                    "BT /F1 12 Tf 50 700 Td (one) Tj ET");
            },
            resources: "/Font <</F1 5 0 R>> /XObject <</Fm0 7 0 R>> /ExtGState <</GS0 8 0 R>>");
        var editor = new PageEditor(session, 0);
        var result = editor.ReplaceParagraph(editor.Objects.OfType<TextObject>().Single(), "one\ntwo");
        Assert.True(result.Done, result.Problem);
        Assert.DoesNotContain("gs", FormData(session));
    }

    [Fact]
    public void ThePaintingOfAFormThatSetsTheModeIsTheOneOrderLooksAt()
    {
        const string Form = "q 1 0 0 rg 0 0 50 50 re f Q BT /F1 12 Tf (x) Tj ET q 0 0 1 rg 100 0 50 50 re f Q";
        var session = Open("/Fm0 Do 7 Tr /Fm0 Do", Form, "/Font <</F1 5 0 R>>");
        var editor = new PageEditor(session, 0);
        var blue = editor.Objects.OfType<PathObject>().Last();
        var result = editor.Order(blue, OrderMove.Backward);
        Assert.False(result.Done);
        Assert.Equal(EditingText.StateBetween, Assert.Single(result.Skipped).Reason);
    }
}
