using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ObjectTableTests
{
    [Fact]
    public void ObjectsLoadOnceAndAreTheSameInstance()
    {
        var document = PdfDocument.Open(TestPdf.Simple());
        Assert.Same(document.Get(2), document.Get(2));
        Assert.Same(document.Get(2), document.Resolve(new PdfReference(2, 0)));
        Assert.Null(document.Get(0));
        Assert.Null(document.Get(-5));
        Assert.Null(document.Get(900));
    }

    [Fact]
    public void ResolveFollowsChainsAndStopsAtLoops()
    {
        var pdf = TestPdf.WithPages(1)
            .Obj(10, "11 0 R").Obj(11, "12 0 R").Obj(12, "(end)")
            .Obj(20, "21 0 R").Obj(21, "20 0 R")
            .Obj(22, "22 0 R")
            .Obj(23, "null");
        var document = PdfDocument.Open(pdf.Finish());
        Assert.IsType<PdfString>(document.Resolve(new PdfReference(10, 0)));
        Assert.Null(document.Resolve(new PdfReference(20, 0)));
        Assert.Null(document.Resolve(new PdfReference(22, 0)));
        Assert.Null(document.Resolve(new PdfReference(23, 0)));
        Assert.Null(document.Resolve(null));
        var number = new PdfNumber(3);
        Assert.Same(number, document.Resolve(number));
    }

    [Fact]
    public void TypedHelpersResolveAndFilter()
    {
        var pdf = TestPdf.WithPages(1)
            .Obj(10, "<</A 11 0 R /B 12 0 R /C 13 0 R /D 14 0 R /E 15 0 R /F 16 0 R /G (text) /H 17 0 R /I 18 0 R>>")
            .Obj(11, "<</K 1>>").Obj(12, "[1 2]").Obj(13, "/Name").Obj(14, "2.5").Obj(15, "true").Obj(16, "90.0")
            .Obj(17, "[0 0 10 20]").Obj(18, "[10 20 0 0]");
        var document = PdfDocument.Open(pdf.Finish());
        var d = document.Dict(null, "x");
        Assert.Null(d);
        var dict = (PdfDictionary)document.Get(10)!;
        Assert.NotNull(document.Dict(dict, "A"));
        Assert.Null(document.Dict(dict, "B"));
        Assert.Equal(2, document.Array(dict, "B")!.Items.Count);
        Assert.Equal("Name", document.Name(dict, "C"));
        Assert.Null(document.Name(dict, "G"));
        Assert.Equal(2.5, document.Number(dict, "D"));
        Assert.Null(document.Integer(dict, "D"));
        Assert.Equal(90, document.Integer(dict, "F"));
        Assert.True(document.Bool(dict, "E"));
        Assert.Null(document.Number(dict, "missing"));
        Assert.Null(document.Stream(dict, "A"));
        Assert.Equal(new PdfRect(0, 0, 10, 20), document.Rect(dict, "H"));
        Assert.Equal(new PdfRect(0, 0, 10, 20), document.Rect(dict, "I"));
        Assert.Null(document.Rect(dict, "B"));
    }

    [Fact]
    public void ObjectThatCannotBeParsedReadsAsNullOnce()
    {
        var pdf = TestPdf.WithPages(1).Obj(10, "<</Broken (never closed");
        var document = PdfDocument.Open(pdf.Finish());
        Assert.IsType<PdfNull>(document.Get(10));
        Assert.Null(document.Resolve(new PdfReference(10, 0)));
        Assert.Single(document.Repairs, r => r.Contains("Object 10 could not be read"));
    }

    [Fact]
    public void ObjectNumbersListWhatIsInUse()
    {
        var document = PdfDocument.Open(TestPdf.WithPages(1).Obj(9, "1").Finish());
        Assert.Equal([1, 2, 3, 4, 9], document.ObjectNumbers.ToArray());
    }

    [Fact]
    public void TableThatStartsAtOneWithTheFreeHeadIsShifted()
    {
        var file = TestPdf.Simple(1);
        string text = TestPdf.Text(file);
        string fixedUp = text.Replace("xref\n0 5\n", "xref\n1 5\n");
        var document = PdfDocument.Open(TestPdf.Latin(fixedUp));
        Assert.Empty(document.Repairs);
        Assert.Single(document.Pages);
    }

    [Fact]
    public void TableEntriesMarkedInUseAtOffsetZeroAreFree()
    {
        var file = TestPdf.Simple(1);
        string text = TestPdf.Text(file);
        string xref = text[text.LastIndexOf("xref\n0", StringComparison.Ordinal)..];
        var lines = xref.Split('\n');
        lines[2] = "0000000000 00000 n ";
        string broken = text[..text.LastIndexOf("xref\n0", StringComparison.Ordinal)] + string.Join("\n", lines);
        Assert.Single(PdfDocument.Open(TestPdf.Latin(broken)).Pages);
    }

    [Fact]
    public void PathOverloadReadsAFile()
    {
        string path = Path.Combine(Path.GetTempPath(), $"lazypdf-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, TestPdf.Simple(2));
        try
        {
            using var document = PdfDocument.Open(path);
            Assert.Equal(2, document.Pages.Count);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ObjectListedAsFreeReadsAsNull()
    {
        // The table calls object 4 free, so it is, whatever the file holds at its old place.
        var file = TestPdf.Simple(1);
        string text = TestPdf.Text(file);
        int xref = text.LastIndexOf("xref\n0", StringComparison.Ordinal);
        var lines = text[xref..].Split('\n');
        lines[6] = "0000000000 00000 f ";
        var document = PdfDocument.Open(TestPdf.Latin(text[..xref] + string.Join("\n", lines)));
        Assert.Null(document.Get(4));
    }
}
