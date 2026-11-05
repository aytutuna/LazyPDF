using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ObjectStreamTests
{
    private static readonly string[] Bodies =
    [
        "<</Type /Catalog /Pages 2 0 R>>",
        "<</Type /Pages /Kids [3 0 R] /Count 1>>",
        "<</Type /Page /Parent 2 0 R /Contents 4 0 R /MediaBox [0 0 100 100]>>",
    ];

    /// <summary>Objects 1 to 3 in object stream 5, content stream 4, cross-reference stream 6.</summary>
    internal static TestPdf ObjectStreamFile(out long xrefOffset, bool predictor = false)
    {
        var header = new StringBuilder();
        var body = new StringBuilder();
        for (int i = 0; i < Bodies.Length; i++)
        {
            header.Append($"{i + 1} {body.Length} ");
            body.Append(Bodies[i]).Append('\n');
        }
        var pdf = new TestPdf("%PDF-1.5\n");
        long content = pdf.Position;
        pdf.Stream(4, "", "q Q");
        long objects = pdf.Position;
        pdf.Stream(5, $"/Type /ObjStm /N 3 /First {header.Length} /Filter /FlateDecode", TestPdf.Deflate(TestPdf.Latin(header.ToString() + body)));
        xrefOffset = pdf.Position;

        var rows = new List<byte[]>
        {
            Row(0, 0, 255), Row(2, 5, 0), Row(2, 5, 1), Row(2, 5, 2), Row(1, content, 0), Row(1, objects, 0), Row(1, xrefOffset, 0),
        };
        byte[] data = predictor ? PngUp(rows) : [.. rows.SelectMany(r => r)];
        string parms = predictor ? "/DecodeParms <</Predictor 12 /Columns 5>>" : "";
        pdf.Stream(6, $"/Type /XRef /Size 7 /W [1 3 1] /Root 1 0 R /Filter /FlateDecode {parms}", TestPdf.Deflate(data));
        return pdf;
    }

    private static byte[] Row(int type, long field, int third) => [(byte)type, (byte)(field >> 16), (byte)(field >> 8), (byte)field, (byte)third];

    private static byte[] PngUp(List<byte[]> rows)
    {
        var output = new List<byte>();
        byte[] previous = new byte[5];
        foreach (var row in rows)
        {
            output.Add(2);
            for (int i = 0; i < 5; i++) output.Add((byte)(row[i] - previous[i]));
            previous = row;
        }
        return [.. output];
    }

    private static byte[] Finish(TestPdf pdf, long xref) => [.. pdf.FinishWithoutXref(), .. TestPdf.Latin($"startxref\n{xref}\n%%EOF\n")];

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ObjectsInObjectStreamsAreRead(bool predictor)
    {
        var pdf = ObjectStreamFile(out long xref, predictor);
        var document = PdfDocument.Open(Finish(pdf, xref));
        Assert.Empty(document.Repairs);
        Assert.Equal("1.5", document.Version);
        Assert.Single(document.Pages);
        Assert.Equal(100, document.Pages[0].MediaBox.Width);
        Assert.Equal("q Q", TestPdf.Text(document.Pages[0].Contents()));
        Assert.True(document.XrefIsStream);
        Assert.Equal(7, document.NextObjectNumber);
        Assert.Equal([1, 2, 3, 4, 5, 6], document.ObjectNumbers.ToArray());
    }

    [Fact]
    public void LostCrossReferenceStreamIsRebuiltFromTheObjectStream()
    {
        var pdf = ObjectStreamFile(out _);
        var document = PdfDocument.Open(Finish(pdf, 12));
        Assert.True(document.XrefRebuilt);
        Assert.Contains(document.Repairs, r => r.Contains("Rebuilt"));
        Assert.Single(document.Pages);
        Assert.Equal("Catalog", document.Name(document.Catalog, "Type"));
    }

    [Fact]
    public void HybridFileTakesObjectsFromTheStreamTheTableLeavesFree()
    {
        var header = $"2 0 3 {Bodies[1].Length + 1} ";
        var data = header + Bodies[1] + "\n" + Bodies[2] + "\n";
        var pdf = new TestPdf("%PDF-1.5\n");
        pdf.Obj(1, Bodies[0]);
        long content = pdf.Position;
        pdf.Stream(4, "", "BT ET");
        long objects = pdf.Position;
        pdf.Stream(5, $"/Type /ObjStm /N 2 /First {header.Length}", data);
        long stream = pdf.Position;
        byte[] rows = [.. Row(2, 5, 0), .. Row(2, 5, 1)];
        pdf.Stream(6, "/Type /XRef /Size 7 /W [1 3 1] /Index [2 2]", rows);
        long table = pdf.Position;
        string text = $"xref\n0 7\n0000000000 65535 f \n{0:D10} 00000 n \n0000000000 00000 f \n0000000000 00000 f \n"
                      + $"{content:D10} 00000 n \n{objects:D10} 00000 n \n{stream:D10} 00000 n \n"
                      + $"trailer\n<</Size 7 /Root 1 0 R /XRefStm {stream}>>\nstartxref\n{table}\n%%EOF\n";
        // Object 1 is the first thing after the header.
        text = text.Replace("0000000000 00000 n \n", $"{9:D10} 00000 n \n");
        var document = PdfDocument.Open([.. pdf.FinishWithoutXref(), .. TestPdf.Latin(text)]);
        Assert.Empty(document.Repairs);
        Assert.Single(document.Pages);
        Assert.Equal("BT ET", TestPdf.Text(document.Pages[0].Contents()));
    }

    [Fact]
    public void ObjectStreamWithAShortHeaderKeepsTheObjectsItHas()
    {
        var pdf = new TestPdf("%PDF-1.5\n");
        string header = "1 0 2 ";
        pdf.Stream(5, $"/Type /ObjStm /N 4 /First {header.Length}", header + Bodies[0] + " ");
        pdf.Obj(2, Bodies[1]).Obj(3, Bodies[2]);
        var document = PdfDocument.Open(pdf.FinishWithoutXref());
        Assert.Contains(document.Repairs, r => r.Contains("header lists"));
        Assert.Equal("Catalog", document.Name(document.Catalog, "Type"));
    }

    [Fact]
    public void ObjectNumberZeroInAnObjectStreamHeaderIsLeftOut()
    {
        var pdf = new TestPdf("%PDF-1.5\n");
        string header = "0 0 1 4 ";
        pdf.Stream(5, $"/Type /ObjStm /N 2 /First {header.Length}", header + "(x) " + Bodies[0] + " ");
        pdf.Obj(2, Bodies[1]).Obj(3, Bodies[2]);
        var document = PdfDocument.Open(pdf.FinishWithoutXref());
        Assert.Equal("Catalog", document.Name(document.Catalog, "Type"));
        Assert.DoesNotContain(0, document.ObjectNumbers);
        foreach (int number in document.ObjectNumbers) document.Set(number, document.Get(number)!);
    }
}
