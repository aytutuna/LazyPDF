using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfAMalformedTests
{
    private static PdfAConversion Convert(byte[] file) =>
        new PdfAConverter(new SystemFonts()).Convert(file, PdfALevel.A2b, StandardsKit.Date);

    [Fact]
    public void AFormThatUsesItselfDoesNotLoop()
    {
        byte[] file = StandardsKit.Compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>",
            extra: pdf => pdf.Stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /XObject << /Fm 9 0 R >> >>", "/Fm Do 0 g 0 0 5 5 re f"));
        Assert.NotNull(Convert(file).Bytes);
        _ = StandardsKit.Check(file);
    }

    [Fact]
    public void AChainOfNestedFormsFarDeeperThanTheCapIsCutShort()
    {
        const int depth = 400;
        byte[] file = StandardsKit.Compliant(content: "/Fm Do", resources: "/XObject <</Fm 9 0 R>>", extra: pdf =>
        {
            for (int i = 0; i < depth; i++)
                pdf.Stream(9 + i, $"/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /XObject << /Fm {10 + i} 0 R >> >>", "/Fm Do");
            pdf.Stream(9 + depth, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "0 g 0 0 5 5 re f");
        });
        _ = StandardsKit.Check(file);
        Assert.NotNull(Convert(file).Bytes);
    }

    [Fact]
    public void ADocumentWithNoPagesIsCheckedWithoutFailing()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        byte[] file = pdf.Finish("/Root 1 0 R");
        Assert.NotEmpty(StandardsKit.Check(file).Issues);
        Assert.NotNull(Convert(file).Bytes);
    }

    [Fact]
    public void AnAnnotationArrayWithJunkInItIsRead()
    {
        byte[] file = StandardsKit.Compliant(page: "/Annots [1 (text) null 99 0 R << /Subtype /Square >> 9 0 R]", extra: pdf => pdf.Obj(9, "<</Type /Annot /Subtype /Sound /Rect [0 0 1 1]>>"));
        Assert.Contains("6.3.1", StandardsKit.Clauses(file));
        var result = Convert(file);
        Assert.NotNull(result.Bytes);
        Assert.DoesNotContain(result.Remaining, i => i.Clause == "6.3.1");
    }

    [Fact]
    public void AFontWithNothingUsableInItIsReportedAndConverted()
    {
        byte[] file = StandardsKit.Compliant(content: "BT /F1 12 Tf (x) Tj ET", resources: "/Font <</F1 9 0 R>>",
            extra: pdf => pdf.Obj(9, "<</Type /Font /Subtype /TrueType /BaseFont /Nothing /FontDescriptor 10 0 R>>").Stream(10, "/Length1 4", new byte[4]));
        Assert.Contains("6.2.11.4.1", StandardsKit.Clauses(file));
        Assert.NotNull(Convert(file).Bytes);
    }

    [Fact]
    public void ACutOffFileIsRefusedOrRepairedButNeverFails()
    {
        byte[] whole = StandardsKit.Compliant();
        for (int cut = 40; cut < whole.Length; cut += 97)
        {
            byte[] part = whole[..cut];
            var result = Convert(part);
            Assert.True(result.Bytes is not null || result.Refusal is not null);
        }
    }

    [Fact]
    public void DamageAtRandomPlacesNeverEscapesAsAnException()
    {
        byte[] whole = StandardsKit.Compliant(page: "/Annots [9 0 R]", resources: "/Font <</F1 11 0 R>>", content: "BT /F1 12 Tf 10 10 Td (Hello) Tj ET 0 0 1 rg 20 20 50 50 re f",
            extra: pdf =>
            {
                pdf.Obj(9, "<</Type /Annot /Subtype /Square /Rect [10 10 50 50] /F 4 /AP <</N 10 0 R>>>>");
                pdf.Stream(10, "/Type /XObject /Subtype /Form /BBox [0 0 40 40]", "0 0 1 rg 0 0 40 40 re f");
                pdf.Obj(11, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
            });
        var random = new Random(7);
        for (int round = 0; round < 150; round++)
        {
            byte[] damaged = (byte[])whole.Clone();
            for (int k = 0; k < 1 + round % 5; k++) damaged[random.Next(damaged.Length)] = (byte)random.Next(256);
            try
            {
                using var document = PdfDocument.Open(damaged);
                _ = PdfAValidator.Validate(document, PdfALevel.A2b);
            }
            catch (PdfReadException)
            {
            }
            var result = Convert(damaged);
            Assert.True(result.Bytes is not null || result.Refusal is not null);
        }
    }

    [Fact]
    public void AHugeNumberOfEntriesInAResourceDictionaryIsAffordable()
    {
        var states = new StringBuilder();
        for (int i = 0; i < 20_000; i++) states.Append($"/G{i} <</ca 1>> ");
        byte[] file = StandardsKit.Compliant(resources: $"/ExtGState <<{states}>>");
        StandardsKit.AssertClean(file);
    }
}
