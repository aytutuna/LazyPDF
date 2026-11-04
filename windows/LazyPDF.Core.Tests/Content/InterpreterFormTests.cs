using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class InterpreterFormTests
{
    private const string FormEntries = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]";

    private static PdfDocument WithForm(string page, string form, string formEntries = FormEntries, string resources = "/XObject <</Fm 5 0 R>> /Font <</F1 6 0 R>>") =>
        ContentTestPdf.Page(page, resources, pdf =>
        {
            pdf.Stream(5, formEntries, form);
            pdf.Obj(6, ContentTestPdf.Helvetica);
        });

    [Fact]
    public void FormContentRunsWithItsMatrixAndFontFromThePage()
    {
        var document = WithForm("/Fm Do", "BT /F1 10 Tf (A) Tj ET", FormEntries + " /Matrix [1 0 0 1 50 60]");
        var r = ContentTestPdf.Run(document);
        Assert.Equal("A", r.Text);
        Assert.Equal(50, r.Glyphs[0].Matrix.E, 6);
        Assert.Equal(60, r.Glyphs[0].Matrix.F, 6);
        Assert.Equal(["form", "endform"], r.Events);
        Assert.Equal(1, r.Where[0].FormDepth);
    }

    [Fact]
    public void TheFormUsesItsOwnResourcesFirst()
    {
        var document = ContentTestPdf.Page("/Fm Do", "/XObject <</Fm 5 0 R>>", pdf =>
        {
            pdf.Stream(5, FormEntries + " /Resources <</Font <</F1 6 0 R>>>>", "BT /F1 10 Tf (A) Tj ET");
            pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>");
        });
        Assert.Equal(600, ContentTestPdf.Run(document).Glyphs[0].Character.Width);
    }

    [Fact]
    public void TheBoxClipsAndFormStateDoesNotLeak()
    {
        var document = WithForm("/Fm Do 0 0 1 1 re f", "q 9 w 0 0 500 500 re f", FormEntries + " /Matrix [1 0 0 1 10 10]");
        var r = ContentTestPdf.Run(document);
        Assert.Equal(new PdfRect(10, 10, 110, 110), r.Paths[0].State.Clip);
        Assert.Equal(1, r.Paths[1].State.LineWidth);
        Assert.Equal(new PdfRect(0, 0, 600, 800), r.Paths[1].State.Clip);
    }

    [Fact]
    public void FormsThatCallThemselvesRunOnce()
    {
        var document = WithForm("/Fm Do", "BT /F1 10 Tf (A) Tj ET /Fm Do", resources: "/XObject <</Fm 5 0 R>> /Font <</F1 6 0 R>>");
        Assert.Equal("A", ContentTestPdf.Run(document).Text);
    }

    [Fact]
    public void TwoFormsCallingEachOtherStop()
    {
        var document = ContentTestPdf.Page("/A Do", "/XObject <</A 5 0 R /B 6 0 R>> /Font <</F1 7 0 R>>", pdf =>
        {
            pdf.Stream(5, FormEntries, "BT /F1 10 Tf (A) Tj ET /B Do");
            pdf.Stream(6, FormEntries, "BT /F1 10 Tf (B) Tj ET /A Do");
            pdf.Obj(7, ContentTestPdf.Helvetica);
        });
        Assert.Equal("AB", ContentTestPdf.Run(document).Text);
    }

    [Fact]
    public void NestingStopsAtTheDepthCap()
    {
        const int count = 40;
        var document = ContentTestPdf.Page("/F0 Do", "/XObject <<" + string.Join(' ', Enumerable.Range(0, count).Select(i => $"/F{i} {5 + i} 0 R")) + ">>", pdf =>
        {
            for (int i = 0; i < count; i++) pdf.Stream(5 + i, FormEntries, $"0 0 1 1 re f /F{i + 1} Do");
        });
        var r = ContentTestPdf.Run(document);
        Assert.Equal(20, r.Paths.Count);
        Assert.Equal(20, r.Where.Max(w => w.FormDepth));
    }

    [Fact]
    public void ARunawayFanOutIsCutByTheOperationLimit()
    {
        // Eight forms, each calling the next ten times: 10^8 operations if let go.
        const int levels = 8;
        var document = ContentTestPdf.Page("/F0 Do", "/XObject <<" + string.Join(' ', Enumerable.Range(0, levels).Select(i => $"/F{i} {5 + i} 0 R")) + ">>", pdf =>
        {
            for (int i = 0; i < levels; i++)
                pdf.Stream(5 + i, FormEntries, i == levels - 1 ? "q Q" : string.Concat(Enumerable.Repeat($"/F{i + 1} Do ", 10)));
        });
        var interpreter = new ContentInterpreter(document);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        interpreter.Run(document.Pages[0], new Recorder());
        Assert.True(interpreter.IsTruncated);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(30), watch.Elapsed.ToString());
    }

    [Fact]
    public void AnUndecodableFormIsSkipped()
    {
        var document = WithForm("/Fm Do 0 0 1 1 re f", "xx", FormEntries + " /Filter /FlateDecode");
        Assert.Single(ContentTestPdf.Run(document).Paths);
    }

    [Fact]
    public void MarkedContentOpenInAFormClosesWithIt()
    {
        var document = WithForm("/Fm Do", "/X BMC 0 0 1 1 re f");
        Assert.Equal(["form", "begin X", "end X", "endform"], ContentTestPdf.Run(document).Events);
    }

    [Fact]
    public void AFormCannotCloseAPageSequence()
    {
        var document = WithForm("/P BMC /Fm Do 0 0 1 1 re f EMC", "EMC");
        Assert.Equal(["begin P", "form", "endform", "end P"], ContentTestPdf.Run(document).Events);
    }

    [Fact]
    public void RunningAFormDirectly()
    {
        var document = WithForm("", "BT /F1 10 Tf (A) Tj ET", FormEntries + " /Resources <</Font <</F1 6 0 R>>>>");
        var form = (PdfStream)document.Get(5)!;
        var r = new Recorder();
        new ContentInterpreter(document).Run(form, r, PdfMatrix.Translate(7, 8));
        Assert.Equal("A", r.Text);
        Assert.Equal(7, r.Glyphs[0].Matrix.E, 6);
    }

    [Fact]
    public void TilingPatternCellRunsOncePerPattern()
    {
        string resources = "/Pattern <</P1 5 0 R>>";
        var document = ContentTestPdf.Page("/Pattern cs /P1 scn 0 0 100 100 re f 200 0 100 100 re f", resources,
            pdf => pdf.Stream(5, "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Matrix [2 0 0 2 0 0]", "0 0 5 5 re f"));
        var r = ContentTestPdf.Run(document);
        Assert.Equal(3, r.Paths.Count);
        Assert.Equal(["pattern", "endform"], r.Events);
        // The cell is inside the pattern, scaled by its matrix.
        Assert.Equal(new PdfRect(0, 0, 10, 10), r.Paths[1].Path.Bounds);
        Assert.Equal([0, 1, 0], r.Where.Select(w => w.FormDepth));
        Assert.NotNull(r.Paths[0].State.FillColor.Pattern);
        Assert.Equal("P1", r.Paths[0].State.FillColor.PatternName!.Value);
    }

    [Fact]
    public void PatternWalkingCanBeSwitchedOff()
    {
        var document = ContentTestPdf.Page("/Pattern cs /P1 scn 0 0 100 100 re f", "/Pattern <</P1 5 0 R>>",
            pdf => pdf.Stream(5, "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10", "0 0 5 5 re f"));
        var r = new Recorder();
        new ContentInterpreter(document) { WalkPatterns = false }.Run(document.Pages[0], r);
        Assert.Single(r.Paths);
    }
}
