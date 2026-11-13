using System.Text;

namespace LazyPDF.Core.Tests;

// Mirrored by the Swift suite. The font is Tests/Fixtures/golden/shaping/script.ttf, made by TrueTypeBuilder.BuildScript,
// and the cases are lines of lines-input.txt: "line <base> <text>" shapes one line, "wrap <base> <width> <text>" breaks
// a text at <width> points of ten point text and dumps each line. <base> is auto, 0 or 1. Code points are printed as hex.
internal static class ShapingGolden
{
    private sealed class OneFont(byte[] data) : IFontSource
    {
        public FontFile? Find(string family, FontStyles style) => new(data);
    }

    private static string N(double v) => new PdfNumber(v).Text;

    private static string Points(string text) => string.Join(" ", text.EnumerateRunes().Select(r => r.Value.ToString("X4")));

    private static int Level(string token) => token == "auto" ? BidiParagraph.Auto : int.Parse(token);

    public static string Dump(byte[] font, string input)
    {
        var sb = new StringBuilder();
        void L(string s) => sb.Append(s).Append('\n');
        var file = new FontFile(font);
        var measure = TrueTypeFont.TryParse(font)!;
        foreach (string row in input.Split('\n'))
        {
            if (row.Length == 0 || row.StartsWith('#')) continue;
            string[] parts = row.Split(' ', row.StartsWith("wrap", StringComparison.Ordinal) ? 4 : 3);
            string text = parts[^1];
            var draw = new PdfFontEmbedder(PdfDocument.Open(TestPdf.Simple(1)), new OneFont(font)).Add("Script Sans", FontStyles.Regular, [text])!;
            if (parts[0] == "line")
            {
                var line = new LineShaper(file, new CmapShaper(), measure, null).Shape(text, Level(parts[1]));
                L($"line {parts[1]} {Points(text)}");
                L($"  rtl {line.RightToLeft} actual {line.NeedsActualText} width {N(line.Width)}");
                L($"  glyphs {string.Join(" ", line.Glyphs.Select(g => $"{g.Shaped.Glyph}:{N(g.Shaped.Advance)}:{N(g.Shaped.XOffset)}:{N(g.Shaped.YOffset)}:{g.Start}-{g.End}{(g.Mirrored ? "m" : "")}"))}");
                L($"  text {Points(line.ActualText)}");
            }
            else
            {
                var lines = draw.Wrap(text, 10, double.Parse(parts[2]), parts[1] == "auto" ? null : parts[1] == "1");
                L($"wrap {parts[1]} {parts[2]} {Points(text)}");
                foreach (string line in lines)
                {
                    L($"  {Points(line)}");
                    L($"    width {N(draw.Width(line, 10))} rtl {draw.IsRightToLeft(line)} encode {Convert.ToHexString(draw.Encode(line))}");
                }
            }
        }
        return sb.ToString();
    }
}
