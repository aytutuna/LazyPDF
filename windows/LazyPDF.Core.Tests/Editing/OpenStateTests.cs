using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// What the edit did not select has to look as it did, whatever state the content leaves open.
public class OpenStateTests
{
    public static TheoryData<string> Pages => new()
    {
        "q 0 0 600 800 re W n 1 0 0 rg BT /F1 12 Tf 50 700 Td (one two three) Tj ET Q",
        "q q q 1 0 0 1 20 -30 cm BT /F1 12 Tf 30 730 Td (one two three) Tj ET Q",
        "2 0 0 2 0 0 cm BT /F1 6 Tf 25 350 Td (one two three) Tj ET",
        "BT /F1 12 Tf 50 700 Td 0.3 Tc 2 Tw 110 Tz 4 Ts (one two three) Tj",
        "BT /F1 12 Tf 14 TL 50 700 Td (one) Tj T* (two three) Tj (more) ' ET",
        "/Span <</MCID 0>> BDC BT /F1 12 Tf 50 700 Td [(one t) -30 (wo three)] TJ ET EMC",
        "BT /F1 12 Tf 1 0 0 1 50 700 Tm (one) Tj 100 0 Td (two) Tj 0 -14 Td (three) Tj ET",
    };

    [Theory]
    [MemberData(nameof(Pages))]
    public void UntouchedGlyphsStayWhereTheyWere(string content)
    {
        string tail = "\n0 0 1 rg 10 10 20 20 re f 0 g BT /F1 10 Tf 200 100 Td (after) Tj ET";
        var session = EditKit.Session(content + tail);
        var before = EditKit.Glyphs(session);
        var result = new PageEditor(session, 0).ReplaceText(EditKit.Find(session, "two"), "2x2");
        Assert.True(result.Done, result.Problem);
        var after = EditKit.Glyphs(session);
        Assert.Equal(string.Concat(before.Select(g => g.Text)).Replace("two", "2x2"), string.Concat(after.Select(g => g.Text)));
        // The text before the word, and everything drawn after the edited operator, is where it was.
        int at = string.Concat(before.Select(g => g.Text)).IndexOf("two", StringComparison.Ordinal);
        Assert.Equal(before.Take(at), after.Take(at));
        Assert.Equal(before.TakeLast(5), after.TakeLast(5));
        string text = EditKit.Latin(session);
        Assert.EndsWith(tail, text);
        Assert.StartsWith(content[..content.IndexOf("(one", StringComparison.Ordinal)], text);
    }

    [Fact]
    public void TheStateAfterTheEditedRunIsTheOneBefore()
    {
        var session = EditKit.Session("BT /F1 12 Tf 50 700 Td 0.4 Tc (one two three) Tj ET");
        new PageEditor(session, 0).SetTextStyle([EditKit.Find(session, "two")], new TextStyleChange(Size: 20, Color: new RgbColor(255, 0, 0), CharSpacing: 1));
        var document = PdfDocument.Open(session.Current.ToArray());
        var seen = new List<(string Text, double Size, double Spacing, RgbColor Color)>();
        new ContentInterpreter(document).Run(document.Pages[0], new Probe(seen));
        Assert.Equal(20, seen.First(s => s.Text == "w").Size);
        Assert.Equal(1, seen.First(s => s.Text == "w").Spacing);
        Assert.Equal(new RgbColor(255, 0, 0), seen.First(s => s.Text == "w").Color);
        // "three" is back to the original size, spacing and colour.
        var three = seen.Skip(seen.FindIndex(s => s.Text == "w") + 2).First(s => s.Text == "t");
        Assert.Equal((12, 0.4, new RgbColor(0, 0, 0)), (three.Size, three.Spacing, three.Color));
    }

    private sealed class Probe(List<(string, double, double, RgbColor)> seen) : ContentVisitor
    {
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) =>
            seen.Add((glyph.Unicode ?? "", context.State.FontSize, context.State.CharSpacing, context.State.FillColor.Rgb));
    }
}
