using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAScopeTests
{
    private const string NoIntent = "";
    private const string Blue = "0 0 1 rg 0 0 5 5 re f";

    private static byte[] LinkWith(string action, PdfALevel level = PdfALevel.A2b) =>
        StandardsKit.Compliant(level, page: "/Annots [9 0 R]", extra: pdf => pdf.Obj(9, $"<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /F 4 /Border [0 0 0] /A {action}>>"));

    private static byte[] Outline(string first, string second, PdfALevel level = PdfALevel.A2b) =>
        StandardsKit.Compliant(level, catalog: "/Outlines 9 0 R", extra: pdf =>
        {
            pdf.Obj(9, "<</Type /Outlines /First 10 0 R /Last 11 0 R /Count 2>>");
            pdf.Obj(10, $"<</Title (a) /Parent 9 0 R /Next 11 0 R {first}>>");
            pdf.Obj(11, $"<</Title (b) /Parent 9 0 R /Prev 10 0 R {second}>>");
        });

    /// <summary>Two pages; the second paints <paramref name="second"/> with no resources of its own.</summary>
    private static byte[] TwoPages(string firstResources, string second, string intents = NoIntent) =>
        StandardsKit.Compliant(resources: firstResources, intents: intents, extra: pdf =>
        {
            pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 12 0 R] /Count 2 /MediaBox [0 0 200 300]>>");
            pdf.Obj(12, "<</Type /Page /Parent 2 0 R /Contents 13 0 R /Resources << >>>>");
            pdf.Stream(13, "", second);
        });

    [Theory]
    [InlineData("NOP")]
    [InlineData("SetState")]
    public void TheDeprecatedActionsAreForbidden(string type)
    {
        Assert.Contains("6.5.1", StandardsKit.Clauses(LinkWith($"<</S /{type}>>")));
        Assert.Contains("6.6.1", StandardsKit.Clauses(LinkWith($"<</S /{type}>>", PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void ActionsOfBookmarksAreChecked()
    {
        StandardsKit.AssertClean(Outline("/A << /S /GoTo /D [3 0 R /Fit] >>", "/Dest [3 0 R /Fit]"));
        Assert.Contains(StandardsKit.Check(Outline("/A << /S /JavaScript /JS (1) >>", "")).Issues, i => i.Clause == "6.5.1" && i.Where == "Outlines");
        Assert.Contains("6.5.1", StandardsKit.Clauses(Outline("", "/A << /S /GoTo /D [3 0 R /Fit] /Next << /S /Launch >> >>")));
        Assert.Contains("6.6.1", StandardsKit.Clauses(Outline("/A << /S /Launch >>", "", PdfALevel.A1b), PdfALevel.A1b));
    }

    [Fact]
    public void OnlyAPdfAIntentSetsWhatDeviceColourIsAllowed()
    {
        byte[] other = StandardsKit.Compliant(content: Blue, extra: pdf =>
            pdf.Obj(6, "<</Type /OutputIntent /S /GTS_PDFX /OutputConditionIdentifier (x) /DestOutputProfile 7 0 R>>"));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(other));
        StandardsKit.AssertClean(StandardsKit.Compliant(content: Blue));
    }

    [Theory]
    [InlineData("scnr")]
    [InlineData("spac")]
    [InlineData("abst")]
    public void AnIntentProfileMustBeOfClassPrtrOrMntr(string kind)
    {
        byte[] file = StandardsKit.Edited(StandardsKit.Compliant(), d =>
        {
            var intent = (PdfDictionary)d.Resolve(d.Array(d.Catalog, "OutputIntents")!.Items[0])!;
            var profile = d.Stream(intent, "DestOutputProfile")!;
            byte[] copy = (byte[])PdfASrgb.SrgbProfile.Clone();
            System.Text.Encoding.ASCII.GetBytes(kind).CopyTo(copy, 12);
            profile.Data = copy;
        });
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.2.3" && i.Where == "Output intent" && i.Message.Contains(kind));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(file));
    }

    [Fact]
    public void ADefaultSpaceOnlyCountsInItsOwnResources()
    {
        byte[] file = TwoPages("/ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>>", Blue);
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Clause == "6.2.4.3" && i.Where == "Page 2");
        Assert.DoesNotContain(StandardsKit.Check(file).Issues, i => i.Where == "Page 1");

        byte[] own = StandardsKit.Compliant(intents: NoIntent, content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: pdf =>
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>> >>", Blue));
        StandardsKit.AssertClean(own);

        byte[] page = StandardsKit.Compliant(intents: NoIntent, content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>> /ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>>", extra: pdf =>
            pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << >>", Blue));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(page));
    }

    [Fact]
    public void AColourSpaceOrImageThatNothingPaintsWithIsNotAUse()
    {
        StandardsKit.AssertClean(StandardsKit.Compliant(intents: NoIntent, content: "", resources: "/ColorSpace <</CS0 /DeviceRGB>>"));
        byte[] unused = StandardsKit.Compliant(intents: NoIntent, content: "", resources: "/XObject <</Im0 9 0 R>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB", new byte[3]));
        StandardsKit.AssertClean(unused);
        byte[] drawn = StandardsKit.Compliant(intents: NoIntent, content: "q 10 0 0 10 0 0 cm /Im0 Do Q", resources: "/XObject <</Im0 9 0 R>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceRGB", new byte[3]));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(drawn));
        byte[] named = StandardsKit.Compliant(intents: NoIntent, content: "/CS0 cs 0 0 1 sc 0 0 5 5 re f", resources: "/ColorSpace <</CS0 /DeviceRGB>>");
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(named));
    }
}
