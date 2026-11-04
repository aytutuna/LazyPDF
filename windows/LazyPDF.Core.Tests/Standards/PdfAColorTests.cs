using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAColorTests
{
    private const string NoIntent = "";

    [Fact]
    public void DeviceRgbWithoutAnOutputIntentIsReportedForEachPart()
    {
        byte[] file = StandardsKit.Compliant(intents: NoIntent);
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(file, PdfALevel.A2b));
        Assert.Contains("6.2.3.3", StandardsKit.Clauses(file, PdfALevel.A1b));
    }

    [Fact]
    public void ADefaultSpaceTakesTheOutputIntentsPlace()
    {
        byte[] file = StandardsKit.Compliant(intents: NoIntent, resources: "/ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>>");
        Assert.DoesNotContain("6.2.4.3", StandardsKit.Clauses(file));
    }

    [Fact]
    public void DeviceCmykNeedsACmykIntentWhileGrayOnlyNeedsOne()
    {
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(StandardsKit.Compliant(content: "0 0 0 1 k 0 0 10 10 re f")));
        Assert.DoesNotContain("6.2.4.3", StandardsKit.Clauses(StandardsKit.Compliant(content: "0.5 g 0 0 10 10 re f")));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(StandardsKit.Compliant(intents: NoIntent, content: "0.5 g 0 0 10 10 re f")));
    }

    [Fact]
    public void ColourInAnImageAndAFormIsFoundThroughTheInterpreter()
    {
        byte[] file = StandardsKit.Compliant(intents: NoIntent, content: "q 0 0 1 rg /Fm Do Q".Replace("0 0 1 rg", "0.5 g"), resources: "/XObject <</Fm 9 0 R>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "1 0 0 RG 0 0 5 5 re S"));
        var issues = StandardsKit.Check(file).Issues.Where(i => i.Clause == "6.2.4.3").ToList();
        Assert.Contains(issues, i => i.Message.Contains("DeviceRGB"));
    }

    [Fact]
    public void AnIntentProfileThatIsTooNewOrDoesNotMatchIsReported()
    {
        byte[] version3 = StandardsKit.Edited(StandardsKit.Compliant(), d => Profile(d).Data = Altered(p => p[8] = 3));
        Assert.Contains(StandardsKit.Check(version3, PdfALevel.A1b).Issues, i => i.Clause == "6.2.2" && i.Where == "Output intent");
        Assert.DoesNotContain(StandardsKit.Check(version3).Issues, i => i.Where == "Output intent");

        byte[] version5 = StandardsKit.Edited(StandardsKit.Compliant(), d => Profile(d).Data = Altered(p => p[8] = 5));
        Assert.Contains(StandardsKit.Check(version5).Issues, i => i.Clause == "6.2.3" && i.Where == "Output intent");

        byte[] wrongSpace = StandardsKit.Edited(StandardsKit.Compliant(), d => Profile(d).Data = Altered(p => p[16] = (byte)'C'));
        Assert.Contains(StandardsKit.Check(wrongSpace).Issues, i => i.Where == "Output intent");

        byte[] garbage = StandardsKit.Edited(StandardsKit.Compliant(), d => Profile(d).Data = new byte[200]);
        Assert.Contains(StandardsKit.Check(garbage).Issues, i => i.Where == "Output intent");
    }

    [Fact]
    public void AnIccBasedSpaceInTheContentIsCheckedTheSameWay()
    {
        string spaces = "/ColorSpace <</CS0 [/ICCBased 9 0 R]>>";
        byte[] bad = StandardsKit.Compliant(resources: spaces, extra: pdf => pdf.Stream(9, "/N 3", new byte[200]));
        Assert.Contains(StandardsKit.Check(bad).Issues, i => i.Clause == "6.2.4.2");
        Assert.Contains(StandardsKit.Check(bad, PdfALevel.A1b).Issues, i => i.Clause == "6.2.3.2");
        byte[] good = StandardsKit.Compliant(resources: spaces, extra: pdf => pdf.Stream(9, "/N 3", PdfASrgb.SrgbProfile));
        Assert.DoesNotContain(StandardsKit.Check(good).Issues, i => i.Clause == "6.2.4.2");
        byte[] mismatch = StandardsKit.Compliant(resources: spaces, extra: pdf => pdf.Stream(9, "/N 1", PdfASrgb.SrgbProfile));
        Assert.Contains(StandardsKit.Check(mismatch).Issues, i => i.Clause == "6.2.4.2");
    }

    [Fact]
    public void ADifferentProfileInASecondIntentIsReported()
    {
        byte[] file = StandardsKit.Compliant(intents: "/OutputIntents [6 0 R 9 0 R]",
            extra: pdf => pdf.Obj(9, "<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (x) /DestOutputProfile 10 0 R>>").Stream(10, "/N 3", PdfASrgb.SrgbProfile));
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Message.Contains("different profiles"));
    }

    [Fact]
    public void AnOutputIntentWithoutAProfileIsReported()
    {
        byte[] file = StandardsKit.Compliant(intents: "/OutputIntents [9 0 R]", extra: pdf => pdf.Obj(9, "<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (x)>>"));
        Assert.Contains(StandardsKit.Check(file).Issues, i => i.Message.Contains("DestOutputProfile"));
    }

    [Fact]
    public void ASeparationNamedTwiceWithDifferentAlternatesIsReported()
    {
        string spaces = "/ColorSpace <</A [/Separation /Gold /DeviceGray 9 0 R] /B [/Separation /Gold /DeviceGray 10 0 R]>>";
        byte[] two = StandardsKit.Compliant(resources: spaces,
            extra: pdf => pdf.Stream(9, "/FunctionType 4 /Domain [0 1] /Range [0 1]", "{}").Stream(10, "/FunctionType 4 /Domain [0 1] /Range [0 1]", "{1 exch sub}"));
        Assert.Contains("6.2.4.4", StandardsKit.Clauses(two));
        byte[] same = StandardsKit.Compliant(resources: spaces.Replace("10 0 R", "9 0 R"), extra: pdf => pdf.Stream(9, "/FunctionType 4 /Domain [0 1] /Range [0 1]", "{}"));
        Assert.DoesNotContain("6.2.4.4", StandardsKit.Clauses(same));
    }

    [Fact]
    public void AnUnknownRenderingIntentIsReported()
    {
        Assert.Contains("6.2.6", StandardsKit.Clauses(StandardsKit.Compliant(content: "/Fancy ri 0 0 1 rg 0 0 5 5 re f")));
        Assert.DoesNotContain("6.2.6", StandardsKit.Clauses(StandardsKit.Compliant(content: "/Perceptual ri 0 0 1 rg 0 0 5 5 re f")));
    }

    [Fact]
    public void AnUndefinedOperatorIsReportedEvenInsideCompatibilityBrackets()
    {
        Assert.Contains("6.2.2", StandardsKit.Clauses(StandardsKit.Compliant(content: "BX 1 2 frob EX")));
        Assert.Contains("6.2.10", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A1b, content: "BX 1 2 frob EX"), PdfALevel.A1b));
    }

    [Fact]
    public void AnIndexedSpaceOverADeviceBaseIsAUseOfIt()
    {
        byte[] file = StandardsKit.Compliant(intents: NoIntent, resources: "/ColorSpace <</CS0 [/Indexed /DeviceRGB 1 <000000FFFFFF>]>>", content: "/CS0 cs 0 sc 0 0 5 5 re f");
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(file));
        Assert.Contains("6.2.3.3", StandardsKit.Clauses(StandardsKit.Compliant(PdfALevel.A1b, intents: NoIntent, resources: "/ColorSpace <</CS0 [/Indexed /DeviceRGB 1 <000000FFFFFF>]>>",
            content: "/CS0 cs 0 sc 0 0 5 5 re f"), PdfALevel.A1b));
        byte[] unpainted = StandardsKit.Compliant(intents: NoIntent, resources: "/ColorSpace <</CS0 [/Indexed /DeviceRGB 1 <000000FFFFFF>]>>", content: "");
        Assert.DoesNotContain("6.2.4.3", StandardsKit.Clauses(unpainted));
    }

    [Fact]
    public void ShadingsPatternsAndGroupsCountOnlyWhenPainted()
    {
        const string shading = "<</ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 10 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 1 1] /N 1>>>>";
        const string resources = "/Shading <</Sh0 " + shading + ">> /Pattern <</P0 <</PatternType 2 /Shading " + shading + ">>>> /XObject <</Fm 9 0 R>>";
        byte[] Page(string content) => StandardsKit.Compliant(intents: NoIntent, resources: resources, content: content,
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Group <</S /Transparency /CS /DeviceRGB>>", ""));
        Assert.DoesNotContain("6.2.4.3", StandardsKit.Clauses(Page("")));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(Page("/Sh0 sh")));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(Page("/Pattern cs /P0 scn 0 0 10 10 re f")));
        Assert.Contains("6.2.4.3", StandardsKit.Clauses(Page("/Fm Do")));
    }

    private static PdfStream Profile(PdfDocument document) =>
        (PdfStream)document.Resolve(((PdfDictionary)document.Resolve(document.Array(document.Catalog, "OutputIntents")!.Items[0])!)["DestOutputProfile"])!;

    private static byte[] Altered(Action<byte[]> change)
    {
        byte[] copy = (byte[])PdfASrgb.SrgbProfile.Clone();
        change(copy);
        return copy;
    }
}
