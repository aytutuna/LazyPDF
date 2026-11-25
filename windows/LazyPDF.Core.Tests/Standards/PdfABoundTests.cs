using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfABoundTests
{
    private const string Helvetica = "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding>>";

    private static PdfAReport Limited(byte[] file, long limit)
    {
        using var document = PdfDocument.Open(file);
        var checker = new PdfAChecker(document, PdfALevel.A2b) { MaxWork = limit };
        checker.Run();
        return checker.Report();
    }

    private static string Name(int i) => $"zz{(char)('a' + i / 26)}{(char)('a' + i % 26)}";

    [Fact]
    public async Task AnActionThatNamesItselfInNextIsJudgedOnce()
    {
        byte[] file = StandardsKit.Compliant(catalog: "/OpenAction 40 0 R", extra: pdf => pdf.Obj(40, "<</S /GoTo /D [3 0 R /Fit] /Next [40 0 R 40 0 R 40 0 R 40 0 R]>>"));
        var check = Task.Run(() => StandardsKit.Check(file));
        Assert.Same(check, await Task.WhenAny(check, Task.Delay(TimeSpan.FromSeconds(20))));
        Assert.True((await check).IsValid);
    }

    [Fact]
    public void ANextChainIsFollowedToItsEnd()
    {
        byte[] chain = StandardsKit.Compliant(catalog: "/OpenAction 40 0 R", extra: pdf =>
        {
            for (int i = 0; i < 18; i++) pdf.Obj(40 + i, $"<</S /GoTo /D [3 0 R /Fit] /Next {41 + i} 0 R>>");
            pdf.Obj(58, "<</S /JavaScript /JS (1)>>");
        });
        Assert.Contains("6.5.1", StandardsKit.Clauses(chain));

        string many = string.Concat(Enumerable.Repeat("<</S /GoTo /D [3 0 R /Fit]>> ", 70));
        byte[] wide = StandardsKit.Compliant(catalog: $"/OpenAction <</S /GoTo /D [3 0 R /Fit] /Next [{many} <</S /Launch>>]>>");
        Assert.Contains("6.5.1", StandardsKit.Clauses(wide));
    }

    [Fact]
    public void AFontShownInAnOversizedFormIsStillReported()
    {
        string content = string.Concat(Enumerable.Repeat("n ", 1_000_100)) + "BT /F1 12 Tf (A) Tj ET";
        byte[] file = StandardsKit.Compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: pdf =>
        {
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <</Font <</F1 10 0 R>>>>", content);
            pdf.Obj(10, Helvetica);
        });
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.1.7" && i.Message == PdfAText.TooMuchContent);
    }

    [Fact]
    public void AFontShownInASoftMaskGroupIsReported()
    {
        byte[] file = StandardsKit.Compliant(content: "/GS0 gs 0 0 1 rg 20 20 100 100 re f", resources: "/ExtGState <</GS0 <</SMask <</S /Luminosity /G 9 0 R>>>>>>", extra: pdf =>
        {
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 200 300] /Group <</S /Transparency /CS /DeviceGray>> /Resources <</Font <</F1 10 0 R>>>>", "BT /F1 12 Tf (A) Tj ET");
            pdf.Obj(10, Helvetica);
        });
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.2.11.4.1" && i.Where == "Font Helvetica");
    }

    [Fact]
    public void AFontShownInAGlyphProcedureIsReported()
    {
        const string type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a 11 0 R>> " +
            "/Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [500] /Resources <</Font <</F2 12 0 R>>>>>>";
        byte[] Page(string procedure) => StandardsKit.Compliant(content: "BT /F1 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, type3);
            pdf.Stream(11, "", procedure);
            pdf.Obj(12, Helvetica);
        });
        Assert.Contains(StandardsKit.Check(Page("500 0 d0 BT /F2 12 Tf (A) Tj ET")).Issues, i => i.Clause == "6.2.11.4.1" && i.Where == "Font Helvetica");
        Assert.DoesNotContain(StandardsKit.Check(Page("500 0 d0")).Issues, i => i.Where == "Font Helvetica");
    }

    [Fact]
    public void ATextRenderModeOfThreeInAGlyphProcedureNeedsNoEmbedding()
    {
        const string type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a 11 0 R>> " +
            "/Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [500] /Resources <</Font <</F2 12 0 R>>>>>>";
        byte[] file = StandardsKit.Compliant(content: "BT /F1 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, type3);
            pdf.Stream(11, "", "500 0 d0 q BT 3 Tr /F2 12 Tf (A) Tj ET Q");
            pdf.Obj(12, Helvetica);
        });
        Assert.DoesNotContain(StandardsKit.Check(file).Issues, i => i.Where == "Font Helvetica");
    }

    [Fact]
    public void ReusingAFormCostsItsOperationsAndNotItsSizeEachTime()
    {
        string form = "q Q" + new string(' ', 1 << 20);
        string content = string.Concat(Enumerable.Repeat("/Fm Do ", 1100));
        StandardsKit.AssertClean(StandardsKit.Compliant(content: content, resources: "/XObject <</Fm 9 0 R>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", form)));
    }

    [Fact]
    public void FormsListedInTheResourcesAreReadOnlyWhileThereIsBudget()
    {
        byte[] file = StandardsKit.Compliant(content: "", resources: "/XObject <<" + string.Concat(Enumerable.Range(0, 60).Select(i => $"/F{i} {20 + i} 0 R ")) + ">>", extra: pdf =>
        {
            for (int i = 0; i < 60; i++) pdf.Stream(20 + i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", new string(' ', 40_000) + Name(i));
        });
        var issues = Limited(file, 1 << 20).Issues;
        Assert.Contains(issues, i => i.Message == PdfAText.UnknownOperator(Name(0)));
        Assert.Contains(issues, i => i.Message == PdfAText.TooMuchContent);
        Assert.DoesNotContain(issues, i => i.Message == PdfAText.UnknownOperator(Name(59)));
        Assert.DoesNotContain(Limited(file, 1L << 30).Issues, i => i.Message == PdfAText.TooMuchContent);
    }

    [Fact]
    public void AppearancesAreReadOnlyWhileThereIsBudget()
    {
        const int count = 300;
        byte[] file = StandardsKit.Compliant(page: "/Annots [" + string.Concat(Enumerable.Range(0, count).Select(i => $"{20 + i} 0 R ")) + "]", extra: pdf =>
        {
            for (int i = 0; i < count; i++)
            {
                pdf.Stream(1000 + i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", new string(' ', 4000) + Name(i));
                pdf.Obj(20 + i, $"<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N {1000 + i} 0 R>>>>");
            }
        });
        var issues = Limited(file, 1 << 18).Issues;
        Assert.Contains(issues, i => i.Message == PdfAText.UnknownOperator(Name(0)));
        Assert.Contains(issues, i => i.Message == PdfAText.TooMuchContent);
        Assert.DoesNotContain(issues, i => i.Message == PdfAText.UnknownOperator(Name(count - 1)));
    }

    [Fact]
    public void APageThatRunsPastTheOperationLimitIsReported()
    {
        string form = string.Concat(Enumerable.Repeat("n ", 100_000));
        string content = string.Concat(Enumerable.Repeat("/Fm Do ", 120));
        byte[] file = StandardsKit.Compliant(content: content, resources: "/XObject <</Fm 9 0 R>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", form));
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Where == "Page 1" && i.Message == PdfAText.TooMuchContent);
    }

    [Fact]
    public void AChainOfGlyphProceduresThatShowTheNextFontIsCutOff()
    {
        const int count = 100;
        byte[] file = StandardsKit.Compliant(content: "BT /F 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F 100 0 R>>", extra: pdf =>
        {
            for (int i = 0; i < count; i++)
            {
                pdf.Obj(100 + i, "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a " + (1000 + i) + " 0 R>> " +
                    "/Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [500] /Resources <</Font <</F " + (101 + i) + " 0 R>>>>>>");
                pdf.Stream(1000 + i, "", "500 0 d0 BT /F 12 Tf (a) Tj ET");
            }
        });
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.1.7" && i.Message == PdfAText.TooMuchContent);
    }

    [Fact]
    public async Task ActionsSharingOneNextListAreJudgedInLinearTime()
    {
        const int count = 20_000;
        byte[] file = StandardsKit.Compliant(catalog: "/OpenAction 40 0 R", extra: pdf =>
        {
            pdf.Obj(39, "[" + string.Concat(Enumerable.Range(0, count).Select(i => $"{40 + i} 0 R ")) + $"{40 + count} 0 R]");
            for (int i = 0; i < count; i++) pdf.Obj(40 + i, "<</S /GoTo /D [3 0 R /Fit] /Next 39 0 R>>");
            pdf.Obj(40 + count, "<</S /JavaScript /JS (1)>>");
        });
        var check = Task.Run(() => StandardsKit.Check(file));
        Assert.Same(check, await Task.WhenAny(check, Task.Delay(TimeSpan.FromSeconds(10))));
        Assert.Contains("6.5.1", (await check).Issues.Select(i => i.Clause));
    }

    [Fact]
    public void WalkingAnnotationsAndTheirStatesUsesTheBudget()
    {
        const int count = 2000;
        byte[] file = StandardsKit.Compliant(page: "/Annots [" + string.Concat(Enumerable.Range(0, count).Select(i => $"{20 + i} 0 R ")) + "]", extra: pdf =>
        {
            pdf.Obj(9, "<<" + string.Concat(Enumerable.Range(0, 256).Select(i => $"/S{i} 10 0 R ")) + ">>");
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "q Q");
            for (int i = 0; i < count; i++) pdf.Obj(20 + i, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 9 0 R>>>>");
        });
        Assert.Contains(Limited(file, 1 << 20).Issues, i => i.Message == PdfAText.TooMuchContent);
        Assert.DoesNotContain(Limited(file, 1L << 30).Issues, i => i.Message == PdfAText.TooMuchContent);
    }

    [Fact]
    public void AFormTheInterpreterDoesNotKeepCostsItsSizeAtEveryPaint()
    {
        const int small = 1100;
        string names = string.Concat(Enumerable.Range(0, small).Select(i => $"/S{i} {20 + i} 0 R "));
        string paints = string.Concat(Enumerable.Range(0, small).Select(i => $"/S{i} Do "));
        PdfAReport Run(int count) => Limited(StandardsKit.Compliant(content: paints + string.Concat(Enumerable.Repeat("/Big Do ", count)),
            resources: $"/XObject <<{names} /Big 9 0 R>>", extra: pdf =>
            {
                pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", new string(' ', 2 << 20));
                for (int i = 0; i < small; i++) pdf.Stream(20 + i, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "q Q");
            }), 8 << 20);
        Assert.Contains(Run(20).Issues, i => i.Message == PdfAText.TooMuchContent);
        Assert.DoesNotContain(Run(1).Issues, i => i.Message == PdfAText.TooMuchContent);
    }

    [Theory]
    [InlineData(25, true)]
    [InlineData(10, false)]
    public void FormsNestedPastTheInterpretersDepthAreReported(int depth, bool reported)
    {
        byte[] file = StandardsKit.Compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: pdf =>
        {
            for (int i = 0; i < depth; i++)
            {
                bool last = i == depth - 1;
                pdf.Stream(9 + i, "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources <<" + (last ? "/Font <</F1 5000 0 R>>" : $"/XObject <</Fm {10 + i} 0 R>>") + ">>",
                    last ? "BT /F1 12 Tf (A) Tj ET" : "/Fm Do");
            }
            pdf.Obj(5000, Helvetica);
        });
        var issues = StandardsKit.Check(file).Issues;
        Assert.Equal(reported, issues.Any(i => i.Message == PdfAText.TooMuchContent));
        if (!reported) Assert.Contains(issues, i => i.Clause == "6.2.11.4.1");
    }

    [Fact]
    public void AnAppearanceThatRunsPastTheOperationLimitIsReported()
    {
        string form = string.Concat(Enumerable.Repeat("n ", 100_000));
        byte[] file = StandardsKit.Compliant(page: "/Annots [20 0 R]", extra: pdf =>
        {
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 100 100]", form);
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <</XObject <</Fm 9 0 R>>>>", string.Concat(Enumerable.Repeat("/Fm Do ", 120)));
            pdf.Obj(20, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 10 0 R>>>>");
        });
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Where.StartsWith("Page 1") && i.Where != "Page 1" && i.Message == PdfAText.TooMuchContent);
    }

    [Fact]
    public void ADeviceImageInAGlyphProcedureCountsAsUsed()
    {
        const string type3 = "<</Type /Font /Subtype /Type3 /FontBBox [0 0 10 10] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs <</a 11 0 R>> " +
            "/Encoding <</Type /Encoding /Differences [97 /a]>> /FirstChar 97 /LastChar 97 /Widths [500] /Resources <</XObject <</Im 12 0 R>>>>>>";
        byte[] Page(string space) => StandardsKit.Compliant(content: "BT /F1 12 Tf 20 20 Td (a) Tj ET", resources: "/Font <</F1 9 0 R>>", extra: pdf =>
        {
            pdf.Obj(9, type3);
            pdf.Stream(11, "", "500 0 d0 /Im Do");
            pdf.Stream(12, $"/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace {space}", "    ");
        });
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(Page("/DeviceCMYK")));
        StandardsKit.AssertClean(Page("/DeviceRGB"));
    }

    [Fact]
    public void HexStringsInObjectStreamsAndContentStreamsAreRead()
    {
        byte[] stored = StandardsKit.Compliant(extra: pdf => pdf.Stream(9, "/Type /ObjStm /N 1 /First 5", "10 0 <</X <ABC>>>"));
        byte[] rebuilt = TestPdf.Replace(stored, "startxref", "startxref\n7");
        Assert.Contains(StandardsKit.Check(rebuilt).Issues, i => i.Clause == "6.1.6" && i.Where == PdfAText.ObjectName(9));

        Assert.Contains("6.1.6", StandardsKit.Clauses(StandardsKit.Compliant(content: "/Span <</X <ABC>>> BDC EMC")));
        StandardsKit.AssertClean(StandardsKit.Compliant(content: "/Span <</X <ABCD>>> BDC EMC"));
        StandardsKit.AssertClean(StandardsKit.Compliant(content: "q BI /W 2 /H 1 /BPC 8 /CS /G ID <( EI Q"));
    }

    [Fact]
    public void InlineImageDataEndsWhereTheParserEndsIt()
    {
        Assert.DoesNotContain("6.1.6", StandardsKit.Clauses(StandardsKit.Compliant(content: "q BI /W 8 /H 1 /BPC 8 /CS /G ID a EI <z EI Q")));
        Assert.Contains("6.1.6", StandardsKit.Clauses(StandardsKit.Compliant(content: "q BI /W 1 /H 1 /BPC 8 /CS /G ID a EI <z> Q")));
    }

    [Fact]
    public void InlineImagesTakeTheShortFilterNamesButNeverCrypt()
    {
        string image = "BI /W 1 /H 1 /BPC 8 /CS /G /F {0} ID {1} EI";
        StandardsKit.AssertClean(StandardsKit.Compliant(content: string.Format(image, "/AHx", "00>")));
        Assert.Contains("6.1.10", StandardsKit.Clauses(StandardsKit.Compliant(content: string.Format(image, "/Crypt", "x"))));
        Assert.Contains("6.1.10", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A1b, content: string.Format(image, "/Crypt", "x")), PdfALevel.A1b));
    }

    [Fact]
    public void AStreamTakesTheFullFilterNamesOnly()
    {
        byte[] Stream(string filter) => StandardsKit.Compliant(catalog: "/Extra 9 0 R", extra: pdf => pdf.Stream(9, $"/Filter {filter}", "abc"));
        Assert.Contains(StandardsKit.Check(Stream("/Fl")).Issues, i => i.Clause == "6.1.7.2" && i.Message.Contains("Fl"));
        Assert.Contains(StandardsKit.Check(Stream("[/ASCIIHexDecode /DCT]")).Issues, i => i.Clause == "6.1.7.2" && i.Message.Contains("DCT"));
        Assert.DoesNotContain("6.1.7.2", StandardsKit.Clauses(Stream("/FlateDecode")));
    }

    [Fact]
    public void StatesPastTheBudgetStillHaveTheirDictionariesCheckedAndAreReported()
    {
        byte[] file = StandardsKit.Compliant(page: "/Annots [30 0 R]", extra: pdf =>
        {
            pdf.Obj(30, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 31 0 R>>>>");
            pdf.Obj(31, "<</A 32 0 R /B 33 0 R /C 34 0 R>>");
            pdf.Stream(32, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", new string(' ', 40_000));
            pdf.Stream(33, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "q Q");
            pdf.Stream(34, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Ref 1 0 R", "q Q");
        });
        var issues = Limited(file, 20_000).Issues;
        Assert.Contains(issues, i => i.Message == PdfAText.ReferenceXObject);
        Assert.Contains(issues, i => i.Message == PdfAText.TooMuchContent && i.Where == "Page 1, annotation 1");
    }

    [Fact]
    public void ManyObjectsAreWalkedInLinearTime()
    {
        const int count = 100_000;
        byte[] file = StandardsKit.Compliant(catalog: "/Extra 39 0 R", extra: pdf =>
        {
            pdf.Obj(39, "[" + string.Concat(Enumerable.Range(0, count).Select(i => $"{40 + i} 0 R ")) + "]");
            for (int i = 0; i < count; i++) pdf.Obj(40 + i, "<<>>");
        });
        var clock = System.Diagnostics.Stopwatch.StartNew();
        StandardsKit.Check(file);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(30), clock.Elapsed.ToString());
    }

    [Fact]
    public void ObjectStreamsAreReadInTheOrderTheFileListsThem()
    {
        byte[] stored = StandardsKit.Compliant(extra: pdf =>
        {
            pdf.Stream(9, "/Type /ObjStm /N 1 /First 5", "10 0 <</X <ABC>>>");
            pdf.Stream(8, "/Type /ObjStm /N 1 /First 5", "11 0 <</X <ABC>>>");
        });
        byte[] rebuilt = TestPdf.Replace(stored, "startxref", "startxref\n7");
        var places = StandardsKit.Check(rebuilt).Issues.Where(i => i.Clause == "6.1.6").Select(i => i.Where).ToList();
        Assert.Equal([PdfAText.ObjectName(9), PdfAText.ObjectName(8)], places);
    }
}
