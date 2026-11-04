using System.Globalization;
using System.Text;
using Xunit;
using static LazyPDF.Core.Tests.TextTestPdf;

namespace LazyPDF.Core.Tests;

public class TextBrokenInputTests
{
    private static string Number(Random random)
    {
        double v = random.Next(8) switch
        {
            0 => 0,
            1 => random.NextDouble() * 1e9,
            2 => -random.NextDouble() * 1e6,
            3 => random.NextDouble() * 1e-6,
            _ => random.NextDouble() * 800 - 100,
        };
        return v.ToString("0.######", CultureInfo.InvariantCulture);
    }

    private static string RandomContent(Random random)
    {
        var sb = new StringBuilder("BT /F1 10 Tf ");
        string[] ops = ["Td", "TD", "Tm", "Tf", "Tc", "Tw", "Tz", "TL", "Ts", "Tr", "T*", "cm", "q", "Q", "BT", "ET"];
        int count = random.Next(5, 120);
        for (int i = 0; i < count; i++)
        {
            switch (random.Next(4))
            {
                case 0:
                    sb.Append('(').Append(string.Concat(Enumerable.Range(0, random.Next(1, 12)).Select(_ => (char)random.Next(65, 123)))).Append(") Tj ");
                    break;
                case 1:
                    sb.Append($"[(ab) {Number(random)} (cd)] TJ ");
                    break;
                default:
                    string op = ops[random.Next(ops.Length)];
                    int operands = op switch { "Tm" or "cm" => 6, "Td" or "TD" => 2, "T*" or "q" or "Q" or "BT" or "ET" => 0, "Tf" => 0, _ => 1 };
                    for (int k = 0; k < operands; k++) sb.Append(Number(random)).Append(' ');
                    sb.Append(op == "Tf" ? "/F1 " + Number(random) + " Tf " : op + " ");
                    break;
            }
        }
        return sb.ToString();
    }

    [Fact]
    public void RandomContentNeverBreaksThePage()
    {
        var random = new Random(11);
        for (int n = 0; n < 150; n++)
        {
            var document = Page(RandomContent(random));
            var page = TextPage.Create(document, document.Pages[0]);
            Assert.Null(TextInvariants.Check(page));
            _ = TextSearch.Find(page, "ab");
            _ = TextSelection.Between(page, 10, 10, 500, 700).GetText();
            _ = TextSelection.InRectangle(page, new PdfRect(0, 0, 600, 800)).Quads();
            _ = page.HitTest(300, 400);
        }
    }

    [Fact]
    public void ADegenerateMatrixLeavesNothingBehind()
    {
        var page = Text("BT /F1 10 Tf 0 0 0 0 100 100 Tm (flat) Tj ET BT /F1 1e12 Tf 1 0 0 1 0 0 Tm (huge) Tj ET");
        Assert.Null(TextInvariants.Check(page));
    }

    [Fact]
    public void AFormThatDrawsItselfIsRunOnce()
    {
        var document = Page("/Fm Do", "/Font <</F1 5 0 R>> /XObject <</Fm 7 0 R>>", "", pdf =>
        {
            Font(pdf, 5);
            pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 600 800] /Resources <</Font <</F1 5 0 R>> /XObject <</Fm 7 0 R>>>>", "/Fm Do " + Line(100, 700, "loop"));
        });
        Assert.Equal("loop", TextPage.Create(document, document.Pages[0]).Text);
    }

    [Fact]
    public void ABrokenFontDictionaryStillGivesGlyphBoxes()
    {
        var document = Page("BT /F1 10 Tf 100 700 Td (abc) Tj ET", "/Font <</F1 5 0 R>>", "", pdf => pdf.Obj(5, "<</Type /Font /Subtype /Type0 /DescendantFonts [<<>>]>>"));
        var page = TextPage.Create(document, document.Pages[0]);
        Assert.Null(TextInvariants.Check(page));
    }

    [Fact]
    public void ExtraArgumentsAreHandled()
    {
        var document = Page(Line(100, 700, "abc"));
        var page = TextPage.Create(document, document.Pages[0]);
        Assert.Equal(new TextRange(0, 3), TextSelection.Of(page, new TextRange(-5, 99)).Ranges[0]);
        Assert.Equal("", page.GetText(new TextRange(9, 3)));
        Assert.Empty(page.Quads(new TextRange(5, 1)));
        Assert.Empty(TextSearch.Find(page, "zzz"));
    }
}
