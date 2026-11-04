using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class OptimizeAuditTests
{
    private static PdfDocument Fixture()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /Metadata 8 0 R /Names <</EmbeddedFiles <</Names [(a.txt) 11 0 R]>>>> /Outlines 13 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [14 0 R] /Resources <</Font <</F1 5 0 R>> /XObject <</Im0 6 0 R>>>>>>");
        pdf.Stream(4, "", "BT /F1 12 Tf (text) Tj ET q 50 0 0 50 0 0 cm /Im0 Do Q");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FontDescriptor 7 0 R>>");
        pdf.Stream(6, "/Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceGray /BitsPerComponent 8", OptimizeKit.Noise(10_000));
        pdf.Obj(7, "<</Type /FontDescriptor /FontName /Helvetica /Flags 32>>");
        pdf.Stream(8, "/Type /Metadata /Subtype /XML", new string('m', 800));
        pdf.Obj(9, "<</Title (T)>>");
        pdf.Stream(10, "/Type /EmbeddedFile", new string('a', 3000));
        pdf.Obj(11, "<</Type /Filespec /F (a.txt) /EF <</F 10 0 R>>>>");
        pdf.Obj(13, "<</Type /Outlines /Count 0>>");
        pdf.Obj(14, "<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents (note)>>");
        pdf.Stream(20, "", new string('u', 5000));
        return PdfDocument.Open(pdf.Finish("/Root 1 0 R /Info 9 0 R"));
    }

    [Fact]
    public void EveryByteBelongsToOneKind()
    {
        using var document = Fixture();
        var audit = new PdfOptimizer(document).Audit();
        Assert.Equal(document.Length, audit.FileSize);
        Assert.Equal(audit.FileSize, audit.Bytes.Values.Sum());
        Assert.InRange(audit.Of(SpaceKind.Images), 10_000, 10_400);
        Assert.InRange(audit.Of(SpaceKind.Attachments), 3000, 3300);
        Assert.InRange(audit.Of(SpaceKind.Metadata), 800, 1000);
        Assert.InRange(audit.Of(SpaceKind.Unreferenced), 5000, 5200);
        Assert.True(audit.Of(SpaceKind.Fonts) > 0);
        Assert.True(audit.Of(SpaceKind.Content) > 0);
        Assert.True(audit.Of(SpaceKind.Annotations) > 0);
        Assert.True(audit.Of(SpaceKind.Structure) > 0);
        Assert.True(audit.Of(SpaceKind.Overhead) > 0);
        Assert.Equal(0, audit.Of(SpaceKind.Forms));
        Assert.All(Enum.GetValues<SpaceKind>(), kind => Assert.False(string.IsNullOrEmpty(OptimizeText.KindName(kind))));
    }

    [Fact]
    public void ARunCountsTheUnreferencedObjects()
    {
        using var document = Fixture();
        var result = new PdfOptimizer(document).Run(OptimizeKit.Off);
        Assert.Equal(1, result.Steps.Single(s => s.Kind == OptimizeStepKind.RemoveUnreferenced).Count);
        Assert.False(OptimizeKit.Everywhere(result.Bytes, new string('u', 100)));
        Assert.True(result.SizeAfter < result.SizeBefore - 4000);
    }
}
