using System.Globalization;
using System.Text;
using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

public class ScanFieldDetectorTests(ITestOutputHelper output)
{
    private const double Dpi = 150;
    private const double K = Dpi / 72;

    // A 400 by 600 point page as a scanner would give it: paper, ink, and what goes wrong with both.
    private sealed class Sheet
    {
        private readonly byte[] _gray = new byte[(int)(400 * K) * (int)(600 * K)];
        private readonly int _width = (int)(400 * K), _height = (int)(600 * K);
        private readonly Random _random = new(7);
        private readonly double _skew;
        private readonly byte _ink;

        public Sheet(double skewDegrees = 0, byte ink = 20, byte paper = 245)
        {
            _skew = Math.Tan(skewDegrees * Math.PI / 180);
            _ink = ink;
            Array.Fill(_gray, paper);
        }

        private void Put(int x, int y)
        {
            y += (int)Math.Round(x * _skew);
            if (x >= 0 && y >= 0 && x < _width && y < _height) _gray[y * _width + x] = _ink;
        }

        private void Fill(double x1, double y1, double x2, double y2)
        {
            for (int y = (int)Math.Round(y1 * K); y < (int)Math.Round(y2 * K); y++)
            {
                for (int x = (int)Math.Round(x1 * K); x < (int)Math.Round(x2 * K); x++) Put(x, y);
            }
        }

        public Sheet Line(double x1, double x2, double y, double thick = 0.7)
        {
            Fill(x1, y, x2, y + thick);
            return this;
        }

        public Sheet Box(double x, double y, double w, double h, double thick = 0.7)
        {
            Line(x, x + w, y, thick).Line(x, x + w, y + h - thick, thick);
            Fill(x, y, x + thick, y + h);
            Fill(x + w - thick, y, x + w, y + h);
            return this;
        }

        public Sheet Rule(double x, double y1, double y2, double thick = 0.7)
        {
            Fill(x, y1, x + thick, y2);
            return this;
        }

        // Words as short broken strokes on a row, the way type or handwriting looks to a run-length scan.
        public Sheet Scribble(double x, double y, double w, double h = 9)
        {
            for (double cx = x; cx < x + w; cx += 1.2 + _random.NextDouble() * 4)
            {
                double top = y + _random.NextDouble() * 2, height = h - 2 + _random.NextDouble() * 3;
                Fill(cx, top, cx + 0.8, top + height);
                if (_random.NextDouble() < 0.35) Fill(cx, top + height / 2, cx + 2.5 + _random.NextDouble() * 2, top + height / 2 + 0.7);
            }
            return this;
        }

        public Sheet Paragraph(double x, double y, double w, int lines)
        {
            for (int i = 0; i < lines; i++) Scribble(x, y + i * 13, w * (0.7 + 0.3 * _random.NextDouble()));
            return this;
        }

        public Sheet Speckle(double density)
        {
            for (int i = 0; i < _gray.Length * density; i++) _gray[_random.Next(_gray.Length)] = _ink;
            return this;
        }

        public PdfRgbaImage Image()
        {
            var rgba = new byte[_gray.Length * 4];
            for (int i = 0; i < _gray.Length; i++)
            {
                rgba[i * 4] = rgba[i * 4 + 1] = rgba[i * 4 + 2] = _gray[i];
                rgba[i * 4 + 3] = 255;
            }
            return new PdfRgbaImage(_width, _height, rgba);
        }
    }

    private sealed class SheetRenderer(Sheet sheet) : IPageRenderer
    {
        public PdfRgbaImage? Render(int pageIndex, double dpi) => sheet.Image();
    }

    private static PdfDocument Page(params (string Text, double X, double Y)[] labels)
    {
        var content = new StringBuilder("q 400 0 0 600 0 0 cm /Im1 Do Q");
        foreach (var (text, x, y) in labels) content.Append(CultureInfo.InvariantCulture, $" BT 3 Tr /F1 10 Tf 1 0 0 1 {x} {600 - y - 8} Tm ({text}) Tj ET");
        return OcrKit.Scan(1, "", content.ToString());
    }

    private static bool Hits(FieldProposal p, double x, double y, double w, double h)
    {
        // The proposal in points from the top; it must cover at least half of the expected box and not be more than twice its area.
        double left = p.Rect.Left, right = p.Rect.Right, top = 600 - p.Rect.Top, bottom = 600 - p.Rect.Bottom;
        double overlap = Math.Max(0, Math.Min(right, x + w) - Math.Max(left, x)) * Math.Max(0, Math.Min(bottom, y + h) - Math.Max(top, y));
        double area = (right - left) * (bottom - top);
        return overlap >= 0.5 * w * h && area <= 2 * w * h;
    }

    // What the form below has, in points from the top left: the lines and boxes a person fills in, and the ones they must not.
    private static readonly (FieldKind Kind, double X, double Y, double W, double H)[] Expected =
    [
        (FieldKind.Text, 90, 62, 200, 16),
        (FieldKind.Text, 90, 102, 250, 16),
        (FieldKind.Text, 90, 142, 150, 16),
        (FieldKind.CheckBox, 50, 200, 12, 12),
        (FieldKind.CheckBox, 50, 225, 12, 12),
        (FieldKind.Text, 50, 270, 300, 24),
        (FieldKind.Text, 50, 320, 120, 18),
        (FieldKind.Text, 220, 320, 130, 18),
    ];

    private static Sheet FilledForm(double skew = 0, byte ink = 20, byte paper = 245)
    {
        var sheet = new Sheet(skew, ink, paper);
        sheet.Scribble(60, 20, 150, 12).Line(60, 340, 36);                        // a heading with its rule: not a blank
        sheet.Line(90, 290, 78).Line(90, 340, 118).Line(90, 240, 158);            // three blanks
        sheet.Scribble(95, 168, 90);                                              // a line already written on
        sheet.Line(90, 240, 182);
        sheet.Box(50, 200, 12, 12).Box(50, 225, 12, 12);                          // check boxes
        sheet.Box(50, 270, 300, 24);                                              // a box
        sheet.Box(50, 320, 300, 18).Rule(170, 320, 338).Rule(220, 320, 338).Scribble(180, 322, 30, 12);   // a row of three cells; the middle one is written in
        sheet.Paragraph(50, 380, 300, 8);                                         // text
        return sheet;
    }

    private (int Found, int Missed, int Extra) Score(IReadOnlyList<FieldProposal> found)
    {
        int hit = Expected.Count(e => found.Any(p => p.Kind == e.Kind && Hits(p, e.X, e.Y, e.W, e.H)));
        int extra = found.Count(p => !Expected.Any(e => p.Kind == e.Kind && Hits(p, e.X, e.Y, e.W, e.H)));
        return (hit, Expected.Length - hit, extra);
    }

    private (int Found, int Missed, int Extra) Run(string name, Sheet sheet)
    {
        var found = FieldDetector.Detect(Page(), 0, new SheetRenderer(sheet));
        var score = Score(found);
        foreach (var p in found.Where(p => !Expected.Any(e => p.Kind == e.Kind && Hits(p, e.X, e.Y, e.W, e.H)))) output.WriteLine($"  extra {p.Kind} {p.Rect.Left:0} {600 - p.Rect.Top:0} {p.Rect.Width:0}x{p.Rect.Height:0} cells {p.Cells}");
        output.WriteLine($"{name}: {score.Found} of {Expected.Length} found, {score.Missed} missed, {score.Extra} extra ({found.Count} proposed)");
        return score;
    }

    [Fact]
    public void ACleanScanGivesItsLinesBoxesAndChecks()
    {
        var score = Run("clean", FilledForm());

        Assert.Equal(0, score.Missed);
        Assert.Equal(0, score.Extra);
    }

    [Fact]
    public void TheTextLayerNamesTheBlanks()
    {
        var found = FieldDetector.Detect(Page(("Name", 50, 62), ("Address", 40, 102), ("I agree", 68, 200)), 0, new SheetRenderer(FilledForm()));

        Assert.All(found, p => Assert.True(p.FromPixels));
        Assert.Equal("Name", found.First(p => Hits(p, 90, 62, 200, 16)).Label);
        Assert.Equal("Address", found.First(p => Hits(p, 90, 102, 250, 16)).Label);
        var check = found.First(p => p.Kind == FieldKind.CheckBox && Hits(p, 50, 200, 12, 12));
        Assert.Equal("I agree", check.Label);
        Assert.Equal("I agree", check.Name);
        Assert.Equal(found.Count, found.Select(p => p.Name).Distinct().Count());
    }

    [Fact]
    public void SpecklesFaintInkAndASlightTurnStillWork()
    {
        var noisy = Run("speckle", FilledForm().Speckle(0.004));
        var faint = Run("faint ink", FilledForm(ink: 130, paper: 235));
        var turned = Run("0.1 degree", FilledForm(skew: 0.1));

        Assert.True(noisy.Missed <= 1 && noisy.Extra <= 1, "speckle");
        Assert.True(faint.Missed <= 1 && faint.Extra <= 1, "faint ink");
        Assert.True(turned.Missed <= 1 && turned.Extra <= 1, "turned by a tenth of a degree");
    }

    [Fact]
    public void ATurnOfAFifthOfADegreeIsTheLimit()
    {
        var a = Run("0.2 degree", FilledForm(skew: 0.2));
        var b = Run("0.5 degree", FilledForm(skew: 0.5));

        // There is no deskew: past a fifth of a degree the longer rules are given up, and nothing is made up in their place.
        Assert.Equal((0, 0), (a.Missed, a.Extra));
        Assert.Equal(0, b.Extra);
    }

    [Fact]
    public void AComboOfEqualBoxesIsOneComb()
    {
        var sheet = new Sheet();
        for (int i = 0; i < 8; i++) sheet.Box(60 + i * 20, 100, 20, 24);

        var found = FieldDetector.Detect(Page(), 0, new SheetRenderer(sheet));

        var comb = Assert.Single(found);
        Assert.Equal(8, comb.Cells);
        Assert.Equal(FieldKind.Text, comb.Kind);
        Assert.InRange(comb.Rect.Width, 159, 161);
    }

    [Fact]
    public void BlankAndTextOnlyPagesGiveNothing()
    {
        Assert.Empty(FieldDetector.Detect(Page(), 0, new SheetRenderer(new Sheet())));
        Assert.Empty(FieldDetector.Detect(Page(), 0, new SheetRenderer(new Sheet().Paragraph(40, 40, 320, 30).Speckle(0.003))));
    }

    [Fact]
    public void ProposalsOverAFieldTheFileHasAreLeftOut()
    {
        var document = Page();
        var sheet = FilledForm();
        var form = PdfForm.Read(document);
        form.AddField(new FieldSpec(FieldKind.Text, "name", 0, new PdfRect(90, 600 - 78 + 1, 290, 600 - 78 + 17)));

        var found = FieldDetector.Detect(document, 0, new SheetRenderer(sheet));

        Assert.DoesNotContain(found, p => Hits(p, 90, 62, 200, 16));
    }

    [Fact]
    public void APageThatDoesNotDrawGivesNothing()
    {
        Assert.Empty(FieldDetector.Detect(Page(), 0, new NoRenderer()));
    }

    private sealed class NoRenderer : IPageRenderer
    {
        public PdfRgbaImage? Render(int pageIndex, double dpi) => null;
    }

    [Fact]
    public void ATextPageIsLeftToTheVectorDetector()
    {
        var calls = new List<int>();
        var document = OcrKit.Pages("BT /F1 12 Tf 50 500 Td (Name:) Tj ET 0.5 w 100 498 m 300 498 l S");

        var found = FieldDetector.Detect(document, new CountingRenderer(calls));

        Assert.Single(found);
        Assert.False(found[0].FromPixels);
        Assert.Empty(calls);
    }

    private sealed class CountingRenderer(List<int> calls) : IPageRenderer
    {
        public PdfRgbaImage? Render(int pageIndex, double dpi)
        {
            calls.Add(pageIndex);
            return null;
        }
    }
}
