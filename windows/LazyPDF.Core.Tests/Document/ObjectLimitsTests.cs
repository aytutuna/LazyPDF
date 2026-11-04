using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ObjectLimitsTests
{
    private static byte[] Row(int type, long second, int third) => [(byte)type, (byte)(second >> 16), (byte)(second >> 8), (byte)second, (byte)third];

    [Fact]
    public void ObjectStreamsThatLiveInEachOtherAreCutOff()
    {
        // Object k is in object stream k + 1, which is in k + 2, and so on: the chain is as long as the file likes.
        const int links = 1600;
        var rows = new List<byte>();
        rows.AddRange(Row(0, 0, 255));
        for (int k = 1; k < links; k++) rows.AddRange(Row(2, k + 1, 0));
        rows.AddRange(Row(0, 0, 0));
        var pdf = new TestPdf("%PDF-1.5\n");
        long xref = pdf.Position;
        rows.AddRange(Row(1, xref, 0));
        pdf.Stream(links + 1, $"/Type /XRef /Size {links + 2} /W [1 3 1] /Root 1 0 R", rows.ToArray());
        byte[] file = [.. pdf.FinishWithoutXref(), .. TestPdf.Latin($"startxref\n{xref}\n%%EOF\n")];
        Assert.Throws<PdfReadException>(() => PdfDocument.Open(file));
    }

    [Fact]
    public void SharedParameterArraysDoNotMultiplyWhenFlattened()
    {
        const int width = 400;
        string refs(int next) => string.Join(" ", Enumerable.Repeat($"{next} 0 R", width));
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(9, "/DecodeParms 10 0 R", "q Q");
        pdf.Obj(10, $"[{refs(11)}]").Obj(11, $"[{refs(12)}]").Obj(12, $"[{refs(13)}]").Obj(13, "null");
        var document = PdfDocument.Open(pdf.Finish());
        var stream = (PdfStream)document.Get(9)!;

        long before = GC.GetAllocatedBytesForCurrentThread();
        Assert.Equal("q Q", TestPdf.Text(document.Data(stream)));
        Assert.True(GC.GetAllocatedBytesForCurrentThread() - before < 32 << 20);
    }

    [Fact]
    public void StreamDataIsReadBeforeTheStreamTakesAnotherNumber()
    {
        var document = PdfDocument.Open(SaveFixtures.Make("aes128"));
        var contents = document.Resolve<PdfStream>(document.Pages[0].Dictionary["Contents"])!;
        int number = document.Add(new PdfDictionary()).Number + 40;
        document.Set(number, contents);
        Assert.Equal(SaveFixtures.PageOne, TestPdf.Text(document.RawData(contents)));
        var reopened = PdfDocument.Open(document.SaveIncremental());
        Assert.Equal(SaveFixtures.PageOne, TestPdf.Text(reopened.Data((PdfStream)reopened.Get(number)!)));
    }

    [Fact]
    public void DecodedSizeCanBeCappedPerCall()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Stream(9, "/Filter /FlateDecode", TestPdf.Deflate(new byte[100_000]));
        var document = PdfDocument.Open(pdf.Finish());
        var stream = (PdfStream)document.Get(9)!;
        Assert.Equal(100_000, document.Data(stream).Length);
        Assert.Throws<PdfReadException>(() => document.Data(stream, 1000));
    }

    [Fact]
    public void XrefStreamIndexThatWrapsALongIsDamaged()
    {
        var pdf = TestPdf.WithPages(1);
        string text = TestPdf.Text(pdf.FinishWithoutXref());
        long xref = pdf.Position;
        var rows = new List<byte>();
        rows.AddRange(Row(0, 0, 255));
        for (int n = 1; n <= 4; n++) rows.AddRange(Row(1, text.IndexOf($"{n} 0 obj", StringComparison.Ordinal), 0));
        rows.AddRange(Row(1, xref, 0));
        rows.AddRange(Row(1, 20, 0));
        pdf.Stream(5, "/Type /XRef /Size 6 /W [1 3 1] /Index [0 6 9223372036854775807 1] /Root 1 0 R", rows.ToArray());
        var document = PdfDocument.Open([.. pdf.FinishWithoutXref(), .. TestPdf.Latin($"startxref\n{xref}\n%%EOF\n")]);
        Assert.True(document.XrefRebuilt);
        Assert.All(document.ObjectNumbers, n => Assert.True(n > 0));
    }
}
