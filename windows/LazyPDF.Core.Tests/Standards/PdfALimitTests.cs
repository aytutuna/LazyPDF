using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfALimitTests
{
    private static byte[] WithPageEntry(string entry, PdfALevel level = PdfALevel.A2b) => StandardsKit.Compliant(level, page: entry);

    private static byte[] DeviceN(int colorants, PdfALevel level) =>
        StandardsKit.Compliant(level, resources: "/ColorSpace <</CS0 [/DeviceN [" + string.Join(' ', Enumerable.Range(0, colorants).Select(i => $"/C{i}")) + "] /DeviceRGB 9 0 R]>>",
            extra: pdf => pdf.Stream(9, "/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1]", "{}"));

    [Fact]
    public void PartOneAllowsEightColorantsAndLaterPartsThirtyTwo()
    {
        Assert.Contains(StandardsKit.Check(DeviceN(12, PdfALevel.A1b), PdfALevel.A1b).Issues, i => i.Clause == "6.1.12" && i.Message.Contains("more than 8"));
        Assert.DoesNotContain("6.1.12", StandardsKit.Clauses(DeviceN(8, PdfALevel.A1b), PdfALevel.A1b));
        Assert.DoesNotContain("6.1.13", StandardsKit.Clauses(DeviceN(12, PdfALevel.A2b)));
        Assert.Contains("6.1.13", StandardsKit.Clauses(DeviceN(33, PdfALevel.A2b)));
    }

    [Fact]
    public void PartOneBoundsRealNumbers()
    {
        Assert.Contains(StandardsKit.Check(WithPageEntry("/Extra 40000.5", PdfALevel.A1b), PdfALevel.A1b).Issues, i => i.Clause == "6.1.12" && i.Message.Contains("40000.5"));
        StandardsKit.AssertClean(WithPageEntry("/Extra 32767 /Other -20000.5 /Third 1000000", PdfALevel.A1b), PdfALevel.A1b);
        Assert.DoesNotContain("6.1.13", StandardsKit.Clauses(WithPageEntry("/Extra 40000.5")));
    }

    [Fact]
    public void LimitsApplyToValuesInContentStreams()
    {
        Assert.Contains("6.1.12", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A1b, content: "0 0 1 rg 20 20 40000.5 100 re f"), PdfALevel.A1b));
        string longName = new('N', 130);
        Assert.Contains("6.1.13", StandardsKit.Clauses(StandardsKit.Compliant(content: $"/{longName} gs 0 0 1 rg 20 20 100 100 re f")));
        Assert.Contains("6.1.13", StandardsKit.Clauses(StandardsKit.Compliant(content: "2147483648 0 0 1 rg 20 20 100 100 re f")));
        StandardsKit.AssertClean(StandardsKit.Compliant(content: "-2147483648 0 0 1 rg 20 20 100 100 re f"));
    }

    [Fact]
    public void LimitsApplyToTheDictionaryOfAnInlineImage()
    {
        const string image = "BI /W 1 /H 1 /BPC 8 /CS /G /D [0 40000.5] ID a EI";
        Assert.Contains(StandardsKit.Check(StandardsKit.Compliant(PdfALevel.A1b, content: image), PdfALevel.A1b).Issues, i => i.Clause == "6.1.12" && i.Message.Contains("40000.5"));
        Assert.DoesNotContain("6.1.13", StandardsKit.Clauses(StandardsKit.Compliant(content: image)));
    }

    [Fact]
    public void TheLowestIntegerIsInRange()
    {
        StandardsKit.AssertClean(WithPageEntry("/Extra -2147483648"));
        Assert.Contains("6.1.13", StandardsKit.Clauses(WithPageEntry("/Extra -2147483649")));
        Assert.Contains("6.1.13", StandardsKit.Clauses(WithPageEntry("/Extra 2147483648")));
    }

    [Fact]
    public void ContentPastTheOperationLimitIsReportedAndNotRun()
    {
        string content = string.Concat(Enumerable.Repeat("n ", 10_100_000));
        var issues = StandardsKit.Check(StandardsKit.Compliant(content: content)).Issues;
        Assert.Contains(issues, i => i.Where == "Page 1" && i.Message == PdfAText.ContentUnreadable);
    }

    [Fact]
    public void AppearancesSharedByManyAnnotationsAreRunOnce()
    {
        var refs = string.Join(' ', Enumerable.Range(0, 400).Select(i => $"{20 + i} 0 R"));
        byte[] file = StandardsKit.Compliant(page: $"/Annots [{refs}]", extra: pdf =>
        {
            pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 50 50]", "0 0 1 rg 0 0 5 5 re f");
            pdf.Obj(11, "<</N 10 0 R>>");
            for (int i = 0; i < 400; i++) pdf.Obj(20 + i, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP 11 0 R>>");
        });
        StandardsKit.AssertClean(file);
    }

    [Fact]
    public void HexStringsNeedAnEvenCountOfHexDigits()
    {
        Assert.Contains(StandardsKit.Check(WithPageEntry("/Extra <ABC>")).Issues, i => i.Clause == "6.1.6");
        Assert.Contains(StandardsKit.Check(WithPageEntry("/Extra <AB CD G1>")).Issues, i => i.Clause == "6.1.6");
        Assert.Contains("6.1.6", StandardsKit.Clauses(WithPageEntry("/Extra <ABC>", PdfALevel.A1b), PdfALevel.A1b));
        StandardsKit.AssertClean(WithPageEntry("/Extra <AB CD 01> /More (<ABC) /Third [<>] /Name /stream"));
    }

    [Fact]
    public void AStreamKeywordTakesNoSpaceAndEndstreamNeedsALineBefore()
    {
        const string data = "0 0 1 rg 20 20 100 100 re f";
        byte[] space = StandardsKit.Compliant(extra: pdf => pdf.Obj(4, $"<</Length {data.Length}>>\nstream \n{data}\nendstream"));
        Assert.Contains(StandardsKit.Check(space).Issues, i => i.Clause == "6.1.7" && i.Message.Contains("stream keyword"));

        byte[] crlf = StandardsKit.Compliant(extra: pdf => pdf.Obj(4, $"<</Length {data.Length}>>\nstream\r\n{data}\nendstream"));
        Assert.DoesNotContain(StandardsKit.Check(crlf).Issues, i => i.Message.Contains("stream keyword"));

        byte[] glued = StandardsKit.Compliant(extra: pdf => pdf.Obj(4, $"<</Length {data.Length}>>\nstream\n{data}endstream"));
        Assert.Contains(StandardsKit.Check(glued).Issues, i => i.Clause == "6.1.7" && i.Message.Contains("/Length"));

        byte[] good = StandardsKit.Compliant(extra: pdf => pdf.Obj(4, $"<</Length {data.Length}>>\nstream\n{data}\r\nendstream"));
        Assert.DoesNotContain(StandardsKit.Check(good).Issues, i => i.Clause == "6.1.7");
    }
}
