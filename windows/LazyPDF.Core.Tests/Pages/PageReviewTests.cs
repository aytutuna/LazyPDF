using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PageReviewTests
{
    private static PdfDocument Import(PdfDocument source, params int[] pages)
    {
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, source, pages, 1);
        return PdfDocument.Open(target.SaveRewrite());
    }

    [Fact]
    public void AnnotationsWrittenDirectlyInAnnotsComeAcross()
    {
        var source = PageTestFiles.Open(1, pageExtra: _ => "/Annots [<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /URI /URI (http://example.com)>>>>]");
        var again = Import(source, 0);
        var annots = again.Array(again.Pages[1].Dictionary, "Annots")!;
        Assert.Single(annots.Items);
        Assert.Equal("Link", again.Name((PdfDictionary)again.Resolve(annots.Items[0])!, "Subtype"));
    }

    [Fact]
    public void AResetActionDoesNotCarryFieldsOfPagesThatStayBehind()
    {
        var source = PageTestFiles.Open(2, "/AcroForm <</Fields [40 0 R 41 0 R]>>", i => i == 0 ? "/Annots [40 0 R]" : "/Annots [41 0 R]", add: pdf => pdf
            .Obj(40, "<</Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (reset) /Rect [0 0 50 20] /A <</S /ResetForm /Fields [41 0 R]>>>>")
            .Obj(41, "<</Type /Annot /Subtype /Widget /FT /Tx /T (salary) /V (secretvalue) /Rect [0 50 50 70]>>"));
        var again = Import(source, 0);
        Assert.DoesNotContain("secretvalue", Encoding.Latin1.GetString(again.SaveRewrite()));
    }

    [Fact]
    public void HiddenLayersStayHiddenInTheCopy()
    {
        var source = PageTestFiles.Open(1, "/OCProperties <</OCGs [40 0 R] /D <</OFF [40 0 R]>>>>", _ => "/Annots [41 0 R]", add: pdf => pdf
            .Obj(40, "<</Type /OCG /Name (Hidden)>>")
            .Obj(41, "<</Type /Annot /Subtype /Square /Rect [0 0 10 10] /OC 40 0 R>>"));
        var again = Import(source, 0);
        var layers = PdfLayers.Read(again);
        var layer = Assert.Single(layers.Layers);
        Assert.False(layer.IsOn);
    }

    [Fact]
    public void AFormKeepsOnlyTheResourcesItsOwnContentNames()
    {
        var source = PageTestFiles.Open(1, pageExtra: _ => "/Annots [40 0 R]", add: pdf => pdf
            .Obj(40, "<</Type /Annot /Subtype /Square /Rect [0 0 10 10] /AP <</N 41 0 R>>>>")
            .Stream(41, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources 42 0 R", "BT /F1 12 Tf (x) Tj ET")
            .Obj(42, "<</Font <</F1 3 0 R>> /XObject <</Im9 43 0 R>>>>")
            .Stream(43, "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8", "UNIQUEIMG"));
        var part = PageAssembly.Extract(source, [0]);
        Assert.DoesNotContain("UNIQUEIMG", Encoding.Latin1.GetString(part.SaveRewrite()));
    }
}
