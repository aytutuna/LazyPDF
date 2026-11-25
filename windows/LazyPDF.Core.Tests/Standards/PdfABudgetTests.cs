using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfABudgetTests
{
    private const string Form = "/Type /XObject /Subtype /Form /BBox [0 0 100 100]";

    private static PdfAReport Limited(byte[] file, long limit)
    {
        using var document = PdfDocument.Open(file);
        var checker = new PdfAChecker(document, PdfALevel.A2b) { MaxWork = limit };
        checker.Run();
        return checker.Report();
    }

    private static bool TooMuch(PdfAReport report) => report.Issues.Any(i => i.Message == PdfAText.TooMuchContent);

    [Fact]
    public void ShowingTextInAFormCostsItsGlyphsAtEveryPaint()
    {
        string text = new('A', 30_000);
        PdfAReport Run(int paints) => Limited(StandardsKit.Compliant(content: string.Concat(Enumerable.Repeat("/Fm Do ", paints)), resources: "/XObject <</Fm 9 0 R>>",
            extra: pdf => pdf.Stream(9, Form, $"BT ({text}) Tj ET")), 1 << 20);
        Assert.True(TooMuch(Run(60)));
        Assert.False(TooMuch(Run(2)));
    }

    [Fact]
    public void AFormTheInterpreterCouldNotReadStillTakesACacheSlot()
    {
        const int small = 1023;
        byte[] unreadable = PdfFilterEncoders.Flate(new byte[(64 << 20) + 1024], System.IO.Compression.CompressionLevel.Fastest);
        string names = string.Concat(Enumerable.Range(0, small).Select(i => $"/S{i} {20 + i} 0 R "));
        string paints = "/Bad Do " + string.Concat(Enumerable.Range(0, small).Select(i => $"/S{i} Do "));
        PdfAReport Run(int count) => Limited(StandardsKit.Compliant(content: paints + string.Concat(Enumerable.Repeat("/Big Do ", count)),
            resources: $"/XObject <</Bad 8000 0 R {names} /Big 9 0 R>>", extra: pdf =>
            {
                pdf.Stream(8000, Form + " /Filter /FlateDecode", unreadable);
                pdf.Stream(9, Form, new string(' ', 1 << 20));
                for (int i = 0; i < small; i++) pdf.Stream(20 + i, Form, "q Q");
            }), 4 << 20);
        Assert.True(TooMuch(Run(20)));
        Assert.False(TooMuch(Run(1)));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void AFormAtTheDepthLimitIsReportedWhenAPatternItInheritsIsPainted(bool inherited)
    {
        const int depth = 20;
        const string cell = "/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10";
        byte[] file = StandardsKit.Compliant(content: (inherited ? "/Pattern cs /P scn " : "") + "/Fm Do", resources: "/XObject <</Fm 9 0 R>> /Pattern <</P 5000 0 R>>", extra: pdf =>
        {
            for (int i = 0; i < depth; i++)
            {
                bool last = i == depth - 1;
                pdf.Stream(9 + i, Form + " /Resources <<" + (last ? "" : $"/XObject <</Fm {10 + i} 0 R>>") + ">>", last ? "0 0 10 10 re f" : "/Fm Do");
            }
            pdf.Stream(5000, cell, "0 0 5 5 re f");
        });
        Assert.Equal(inherited, TooMuch(StandardsKit.Check(file)));
    }

    [Fact]
    public void AColourSetAtTheDepthLimitIsNotAPatternToSkip()
    {
        const int depth = 20;
        byte[] file = StandardsKit.Compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: pdf =>
        {
            for (int i = 0; i < depth; i++)
            {
                bool last = i == depth - 1;
                pdf.Stream(9 + i, Form + " /Resources <<" + (last ? "/ColorSpace <</Cs [/ICCBased 7 0 R]>>" : $"/XObject <</Fm {10 + i} 0 R>>") + ">>",
                    last ? "/Cs cs 0 0 0 scn 0 0 10 10 re f" : "/Fm Do");
            }
        });
        Assert.False(TooMuch(StandardsKit.Check(file)));
    }

    [Fact]
    public void ADeviceColourUsedOverAndOverIsReportedOnce()
    {
        byte[] file = StandardsKit.Compliant(content: string.Concat(Enumerable.Repeat("1 0 0 0 k 0 0 5 5 re f ", 5000)));
        Assert.Single(StandardsKit.Check(file).Issues, i => i.Clause == "6.2.4.3");
    }

    [Fact]
    public void TheTaggedContentIsNotReadAgainOnceTheBudgetIsGone()
    {
        using var document = PdfDocument.Open(StandardsKit.Tagged(PdfALevel.A2a));
        var checker = new PdfAChecker(document, PdfALevel.A2a) { MaxWork = 1 };
        checker.Run();
        Assert.Contains(checker.StructureIssues, i => i.Message == PdfAText.TooMuchContent);
    }
}
