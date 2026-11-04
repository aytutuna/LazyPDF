using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Files built to be awkward: loops, a very long chain, references to nothing, data that does not decode.
public class PageImportLimitTests
{
    private static byte[] Awkward(Action<TestPdf> add, string pageResources = "/Font <</F1 10 0 R>>") =>
        new TestPdf()
            .Also(pdf =>
            {
                pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
                pdf.Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 100 100]>>");
                pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 5 0 R /Resources <<{pageResources}>>>>");
                pdf.Obj(4, "<</Type /Page /Parent 2 0 R /Contents 6 0 R>>");
                pdf.Stream(5, "", "BT /F1 12 Tf (Page 1) Tj ET /X Do /F2 gs /G gs");
                pdf.Stream(6, "", "BT (Page 2) Tj ET");
                pdf.Obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
                add(pdf);
            })
            .Finish();

    [Fact]
    public void ObjectsThatPointAtEachOtherAreCopiedOnce()
    {
        byte[] file = Awkward(pdf =>
        {
            pdf.Obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /FontDescriptor 11 0 R /Self 10 0 R>>");
            pdf.Obj(11, "<</Type /FontDescriptor /Font 10 0 R /Loop [11 0 R 10 0 R]>>");
        });
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(file), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var font = again.Dict(again.Dict(again.Pages[1].Resources, "Font"), "F1")!;
        Assert.Same(font, again.Resolve(font["Self"]));
        Assert.Same(font, again.Dict((PdfDictionary)again.Resolve(font["FontDescriptor"])!, "Font"));
    }

    [Fact]
    public void ALongChainOfObjectsNeedsNoStack()
    {
        const int Length = 60_000;
        byte[] file = Awkward(pdf =>
        {
            pdf.Obj(10, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Chain 100 0 R>>");
            for (int i = 0; i < Length; i++) pdf.Obj(100 + i, i + 1 < Length ? $"<</Next {101 + i} 0 R>>" : "<</End true>>");
        });
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(file), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        int links = 0;
        var node = again.Resolve(again.Dict(again.Dict(again.Pages[1].Resources, "Font"), "F1")!["Chain"]) as PdfDictionary;
        for (; node is not null && links <= Length; node = again.Dict(node, "Next")) links++;
        Assert.Equal(Length, links);
    }

    [Fact]
    public void ReferencesToNothingAreLeftOut()
    {
        byte[] file = Awkward(pdf => { }, "/Font <</F1 10 0 R /F2 77 0 R>> /ExtGState <</G 78 0 R>>");
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(file), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        Assert.Empty(again.Repairs);
        Assert.False(again.Dict(again.Pages[1].Resources, "Font")!.ContainsKey("F2"));
    }

    [Fact]
    public void AStreamThatDoesNotDecodeIsCopiedAsItIs()
    {
        byte[] bad = [0x78, 0x9C, 0x01, 0x02, 0x03];
        byte[] file = Awkward(pdf => pdf.Stream(7, "/Filter /FlateDecode", bad), pageResources: "/Font <</F1 10 0 R>> /XObject <</X 7 0 R>>");
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(file), [0], 1);
        var again = PdfDocument.Open(target.SaveRewrite());
        var stream = (PdfStream)again.Resolve(again.Dict(again.Pages[1].Resources, "XObject")!["X"])!;
        Assert.Equal(bad, again.RawData(stream));
    }

    [Fact]
    public void APageWhoseContentCannotBeReadKeepsAllItsResources()
    {
        byte[] bad = [0x78, 0x9C, 0x01, 0x02, 0x03];
        byte[] file = Awkward(pdf => pdf.Stream(7, "/Filter /FlateDecode", bad), pageResources: "/Font <</F1 10 0 R /F9 10 0 R>>")
            .Replace("/Contents 5 0 R", "/Contents 7 0 R");
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, PdfDocument.Open(file), [0], 1);
        Assert.True(target.Pages[1].Resources!.ContainsKey("Font"));
        Assert.Equal(2, target.Dict(target.Pages[1].Resources, "Font")!.Count);
    }

    [Fact]
    public void ADamagedSourceStillGivesItsPages()
    {
        byte[] file = PageImportTests.Source();
        byte[] cut = file[..(file.Length - 40)];
        var source = PdfDocument.Open(cut);
        var target = PageTestFiles.Open(1);
        PageOperations.ImportPages(target, source, [0, 1, 2], 1);
        Assert.Equal(4, target.Pages.Count);
        Assert.Empty(PdfDocument.Open(target.SaveRewrite()).Repairs);
    }
}

internal static class PageTestPdfExtensions
{
    public static TestPdf Also(this TestPdf pdf, Action<TestPdf> add)
    {
        add(pdf);
        return pdf;
    }

    public static byte[] Replace(this byte[] file, string find, string replacement) => TestPdf.Replace(file, find, replacement);
}
