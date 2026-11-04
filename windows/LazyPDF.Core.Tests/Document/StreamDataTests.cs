using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class StreamDataTests
{
    private static PdfDocument Open(TestPdf pdf) => PdfDocument.Open(pdf.Finish());

    [Fact]
    public void IndirectLengthFilterAndParametersAreResolved()
    {
        // PNG "Up" rows: the second row stores its difference from the first.
        byte[] predicted = [2, 10, 20, 30, 2, 1, 2, 3];
        byte[] packed = TestPdf.Deflate(predicted);
        var pdf = TestPdf.WithPages(1)
            .Obj(20, "/FlateDecode")
            .Obj(21, "<</Predictor 12 /Columns 3>>")
            .Obj(22, "[20 0 R]")
            .Obj(23, "[21 0 R]")
            .Obj(25, packed.Length.ToString());
        pdf.Stream(24, "/Filter 22 0 R /DecodeParms 23 0 R", packed);
        pdf.Stream(26, "/Filter 20 0 R /DecodeParms 21 0 R", packed, length: -1);
        var document = Open(pdf);
        byte[] expected = [10, 20, 30, 11, 22, 33];
        Assert.Equal(expected, document.Data((PdfStream)document.Get(24)!));
        Assert.Equal(packed, document.RawData((PdfStream)document.Get(24)!));
        Assert.Equal(expected, document.Data((PdfStream)document.Get(26)!));
    }

    [Fact]
    public void LengthInAnotherObjectIsFollowed()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Write("30 0 obj\n<</Length 31 0 R>>\nstream\nhello world\nendstream\nendobj\n31 0 obj\n11\nendobj\n");
        var document = PdfDocument.Open(pdf.FinishWithoutXref());
        var stream = document.Resolve<PdfStream>(new PdfReference(30, 0))!;
        Assert.Equal("hello world", TestPdf.Text(document.RawData(stream)));
        Assert.DoesNotContain(document.Repairs, r => r.Contains("/Length"));
    }

    [Fact]
    public void LengthInAMissingObjectFallsBackToEndstream()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Write("30 0 obj\n<</Length 99 0 R>>\nstream\nhello world\nendstream\nendobj\n");
        var document = PdfDocument.Open(pdf.FinishWithoutXref());
        Assert.Equal("hello world", TestPdf.Text(document.RawData(document.Resolve<PdfStream>(new PdfReference(30, 0))!)));
    }

    [Fact]
    public void UnsupportedFilterIsAReadException()
    {
        var pdf = TestPdf.WithPages(1).Stream(9, "/Filter /JBIG2Decode", "x");
        var document = Open(pdf);
        var e = Assert.Throws<PdfReadException>(() => document.Data((PdfStream)document.Get(9)!));
        Assert.Equal(PdfReadProblem.Unsupported, e.Problem);
    }

    [Fact]
    public void CorruptFlateDataIsAReadException()
    {
        var pdf = TestPdf.WithPages(1).Stream(9, "/Filter /FlateDecode", "this is not zlib data at all");
        var document = Open(pdf);
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => document.Data((PdfStream)document.Get(9)!)).Problem);
    }

    [Fact]
    public void StreamMadeInMemoryGivesItsOwnData()
    {
        var document = PdfDocument.Open(TestPdf.Simple(1));
        var stream = new PdfStream(new PdfDictionary(), TestPdf.Latin("abc"));
        var reference = document.Add(stream);
        Assert.Same(stream.Data, document.RawData(stream));
        Assert.Equal("abc", TestPdf.Text(document.Data(stream)));
        Assert.Equal(reference.Number, stream.Number);
        Assert.Same(stream, document.Get(reference.Number));
    }

    [Fact]
    public void StreamKeywordFollowedByCarriageReturnOnly()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Write("30 0 obj\n<</Length 5>>\nstream\rhello\nendstream\nendobj\n");
        var document = PdfDocument.Open(pdf.FinishWithoutXref());
        Assert.Equal("hello", TestPdf.Text(document.RawData(document.Resolve<PdfStream>(new PdfReference(30, 0))!)));
    }
}
