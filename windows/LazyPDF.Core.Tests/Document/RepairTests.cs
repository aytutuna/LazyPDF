using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class RepairTests
{
    private static PdfDocument OpenWithPages(byte[] file, int pages, string? repair)
    {
        var document = PdfDocument.Open(file);
        Assert.Equal(pages, document.Pages.Count);
        if (repair is null) Assert.Empty(document.Repairs);
        else Assert.Contains(document.Repairs, r => r.Contains(repair, StringComparison.OrdinalIgnoreCase));
        return document;
    }

    [Fact]
    public void AGoodFileNeedsNoRepair() => OpenWithPages(TestPdf.Simple(3), 3, null);

    [Fact]
    public void BytesBeforeTheHeaderAreCutOff()
    {
        var file = TestPdf.Latin("junk before\r\n").Concat(TestPdf.Simple(2)).ToArray();
        var document = OpenWithPages(file, 2, "before the %PDF header");
        Assert.Equal(file.Length - 13, document.Length);
    }

    [Fact]
    public void HeaderTooFarInIsNotAPdf()
    {
        var file = new byte[2000].Concat(TestPdf.Simple()).ToArray();
        Assert.Equal(PdfReadProblem.NotPdf, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file)).Problem);
    }

    [Fact]
    public void MissingStartxrefRebuildsTheTable() =>
        OpenWithPages(TestPdf.Replace(TestPdf.Simple(), "startxref", "startxxxxx"), 2, "startxref");

    [Fact]
    public void StartxrefPastTheEndRebuildsTheTable()
    {
        var document = OpenWithPages(new TestPdf().Obj(1, "<</Type /Catalog /Pages 2 0 R>>").Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1>>")
            .Obj(3, "<</Type /Page /Parent 2 0 R>>").Finish(startxref: "99999999"), 1, "startxref");
        Assert.True(document.XrefRebuilt);
    }

    [Fact]
    public void StartxrefPointingAtGarbageRebuildsTheTable()
    {
        var file = TestPdf.Simple();
        string text = TestPdf.Text(file);
        string start = text[(text.LastIndexOf("startxref", StringComparison.Ordinal) + 10)..].Split('\n')[0];
        OpenWithPages(TestPdf.Replace(file, "startxref\n" + start, "startxref\n20"), 2, "rebuilt");
    }

    [Fact]
    public void OffsetsSlightlyOffAreFoundByTheirHeaders()
    {
        var document = OpenWithPages(TestPdf.WithPages(2).Finish(shift: 7), 2, "found at byte");
        Assert.False(document.XrefRebuilt);
    }

    [Fact]
    public void OffsetsNamingAnotherObjectAreFoundByTheirHeaders()
    {
        var table = TestPdf.Text(TestPdf.Simple(2));
        // Object 3 listed at the offset of object 4.
        int xref = table.LastIndexOf("xref\n0", StringComparison.Ordinal);
        var lines = table[xref..].Split('\n');
        lines[5] = lines[6];
        var broken = TestPdf.Latin(table[..xref] + string.Join("\n", lines));
        var document = PdfDocument.Open(broken);
        Assert.Equal(2, document.Pages.Count);
        Assert.Contains(document.Repairs, r => r.Contains("Object 3"));
    }

    [Fact]
    public void BrokenPrevRebuildsTheTableAndTheNewestObjectWins()
    {
        var pdf = TestPdf.WithPages(1);
        byte[] first = pdf.Finish();
        long update = first.Length;
        string objectText = "3 0 obj\n<</Type /Page /Parent 2 0 R /Rotate 90 /Contents 4 0 R>>\nendobj\n";
        string text = objectText + "xref\n3 1\n" + $"{update:D10} 00000 n \n" + "trailer\n<</Size 5 /Root 1 0 R /Prev 5000000>>\nstartxref\n" + (update + objectText.Length) + "\n%%EOF\n";
        var document = OpenWithPages([.. first, .. TestPdf.Latin(text)], 1, "rebuilt");
        Assert.Equal(90, document.Pages[0].Rotate);
    }

    [Fact]
    public void PrevLoopRebuildsTheTable()
    {
        var file = TestPdf.Simple(1);
        string text = TestPdf.Text(file);
        int xref = text.LastIndexOf("xref\n0", StringComparison.Ordinal);
        string looped = text.Replace("/Root 1 0 R>>", $"/Root 1 0 R /Prev {xref}>>");
        OpenWithPages(TestPdf.Latin(looped), 1, "point back");
    }

    [Fact]
    public void WrongLengthIsFoundByEndstream()
    {
        var pdf = TestPdf.WithPages(1).Stream(9, "", "twelve bytes", length: 3).Stream(10, "", "ten bytes!", length: 500).Stream(11, "", "no length", length: -1);
        var document = OpenWithPages(pdf.Finish(), 1, null);
        Assert.Equal("twelve bytes", TestPdf.Text(document.RawData((PdfStream)document.Get(9)!)));
        Assert.Equal("ten bytes!", TestPdf.Text(document.RawData((PdfStream)document.Get(10)!)));
        Assert.Equal("no length", TestPdf.Text(document.RawData((PdfStream)document.Get(11)!)));
        Assert.Equal(3, document.Repairs.Count(r => r.Contains("/Length")));
    }

    [Fact]
    public void StreamWithoutEndstreamEndsAtEndobj()
    {
        var pdf = TestPdf.WithPages(1).Stream(9, "", "cut short", length: 400, endstream: false);
        var document = OpenWithPages(pdf.Finish(), 1, null);
        Assert.Equal("cut short", TestPdf.Text(document.RawData((PdfStream)document.Get(9)!)));
        Assert.Contains(document.Repairs, r => r.Contains("/Length"));
    }

    [Fact]
    public void MissingEndobjIsNoProblem()
    {
        var file = TestPdf.Latin(TestPdf.Text(TestPdf.Simple(2)).Replace("endobj\n", ""));
        // The offsets moved, so the table is wrong as well: both are got round.
        Assert.Equal(2, PdfDocument.Open(file).Pages.Count);
        var rebuilt = TestPdf.Replace(file, "startxref", "startxxxxx");
        Assert.Equal(2, PdfDocument.Open(rebuilt).Pages.Count);
    }

    [Fact]
    public void MissingTrailerRebuildsAndFindsTheCatalog()
    {
        var file = TestPdf.WithPages(2).FinishWithoutXref();
        var document = OpenWithPages(file, 2, "no trailer");
        Assert.Equal("Catalog", document.Name(document.Catalog, "Type"));
    }

    [Fact]
    public void TrailerWithoutRootFindsTheCatalogByType()
    {
        var document = OpenWithPages(TestPdf.WithPages(2).Finish(trailer: ""), 2, "catalog");
        Assert.NotNull(document.Trailer["Root"]);
    }

    [Fact]
    public void TruncatedFileKeepsWhatIsThere()
    {
        var file = TestPdf.Simple(3);
        var cut = file[..(file.Length - 120)];
        var document = PdfDocument.Open(cut);
        Assert.True(document.XrefRebuilt);
        Assert.Equal(3, document.Pages.Count);
    }

    [Fact]
    public void NoCatalogMakesOneFromThePageTree()
    {
        var pdf = new TestPdf().Obj(2, "<</Type /Pages /Kids [3 0 R 4 0 R] /Count 2>>").Obj(3, "<</Type /Page /Parent 2 0 R>>").Obj(4, "<</Type /Page /Parent 2 0 R>>");
        OpenWithPages(pdf.FinishWithoutXref(), 2, "made one");
    }

    [Fact]
    public void NoTreeEitherMakesOneFromThePages()
    {
        var pdf = new TestPdf().Obj(3, "<</Type /Page /MediaBox [0 0 10 10]>>").Obj(4, "<</Type /Page /MediaBox [0 0 20 20]>>");
        var document = OpenWithPages(pdf.FinishWithoutXref(), 2, "made a page tree");
        Assert.Equal(20, document.Pages[1].MediaBox.Width);
    }

    [Fact]
    public void LaterDefinitionOfAnObjectWinsInTheScan()
    {
        var pdf = TestPdf.WithPages(1).Obj(3, "<</Type /Page /Parent 2 0 R /Rotate 180 /Contents 4 0 R>>");
        var document = OpenWithPages(pdf.FinishWithoutXref(), 1, "scanning");
        Assert.Equal(180, document.Pages[0].Rotate);
    }

    [Fact]
    public void PdfInsideAStreamIsNotMistakenForObjects()
    {
        string inner = "9 0 obj\n<</Type /Page /Rotate 90>>\nendobj\n";
        var pdf = TestPdf.WithPages(1).Stream(8, "", "%PDF-1.4\n" + inner + "trailer\n<</Root 9 0 R>>\n");
        var document = OpenWithPages(pdf.FinishWithoutXref(), 1, "scanning");
        Assert.Equal(0, document.Pages[0].Rotate);
    }

    [Fact]
    public void NoPagesAnywhereIsDamaged()
    {
        var file = TestPdf.Latin("%PDF-1.4\n1 0 obj\n<</Foo 1>>\nendobj\n");
        Assert.Equal(PdfReadProblem.Damaged, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file)).Problem);
    }

    [Fact]
    public void UnclosedStringsDoNotMakeTheScanQuadratic()
    {
        var pdf = TestPdf.WithPages(1);
        for (int i = 0; i < 3000; i++) pdf.Write($"{100 + i} 0 obj\n(never closed\n");
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var document = PdfDocument.Open(pdf.FinishWithoutXref());
        Assert.Single(document.Pages);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(5), $"took {watch.Elapsed}");
    }

    [Fact]
    public void ManyBrokenStreamsStayLinear()
    {
        var pdf = TestPdf.WithPages(1);
        var data = new string('x', 200);
        for (int i = 0; i < 5000; i++) pdf.Stream(100 + i, "", data, length: 7);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var document = PdfDocument.Open(pdf.Finish());
        for (int i = 0; i < 5000; i++) Assert.Equal(200, document.RawData((PdfStream)document.Get(100 + i)!).Length);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), $"took {watch.Elapsed}");
    }

    [Fact]
    public void RepairListIsCapped()
    {
        var pdf = TestPdf.WithPages(1);
        for (int i = 0; i < 300; i++) pdf.Stream(100 + i, "", "abc", length: 99);
        var document = PdfDocument.Open(pdf.Finish());
        for (int i = 0; i < 300; i++) document.RawData((PdfStream)document.Get(100 + i)!);
        Assert.Equal(101, document.Repairs.Count);
    }

    [Fact]
    public void NotPdfAndEmptyFilesAreRefused()
    {
        foreach (byte[] file in new[] { Array.Empty<byte>(), TestPdf.Latin("hello"), TestPdf.Latin("%PDF") })
        {
            Assert.Equal(PdfReadProblem.NotPdf, Assert.Throws<PdfReadException>(() => PdfDocument.Open(file)).Problem);
        }
    }

    [Fact]
    public void MutatedFilesOpenOrFailCleanly()
    {
        var basis = TestPdf.Simple(4);
        var random = new Random(376);
        for (int round = 0; round < 400; round++)
        {
            var file = (byte[])basis.Clone();
            int edits = 1 + round % 6;
            for (int e = 0; e < edits; e++) file[random.Next(file.Length)] = (byte)random.Next(256);
            if (round % 5 == 0) file = file[..random.Next(file.Length)];
            try
            {
                var document = PdfDocument.Open(file);
                foreach (var page in document.Pages) page.Contents();
            }
            catch (PdfReadException)
            {
            }
        }
    }
}
