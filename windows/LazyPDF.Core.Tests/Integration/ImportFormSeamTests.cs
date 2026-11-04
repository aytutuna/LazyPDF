using Xunit;

namespace LazyPDF.Core.Tests;

public class ImportFormSeamTests
{
    // Two pages-worth of AcroForm: a text field per page, a font under the name Helv in /DR.
    private static byte[] Sheet(string fontBase, string fields = "a b", string co = "")
    {
        var pdf = new TestPdf();
        var names = fields.Split(' ');
        string refs = string.Join(" ", names.Select((_, i) => $"{20 + i} 0 R"));
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 4 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [10 0 R] /Count 1 /MediaBox [0 0 300 300]>>");
        pdf.Obj(3, $"<</Type /Font /Subtype /Type1 /BaseFont /{fontBase} /Encoding /WinAnsiEncoding>>");
        pdf.Obj(4, $"<</Fields [{refs}] {co} /DA (/Helv 12 Tf 0 g) /DR <</Font <</Helv 3 0 R>>>>>>");
        pdf.Obj(10, $"<</Type /Page /Parent 2 0 R /Annots [{refs}] /Resources <</Font <</Helv 3 0 R>>>>>>");
        for (int i = 0; i < names.Length; i++)
        {
            pdf.Obj(20 + i, $"<</Type /Annot /Subtype /Widget /FT /Tx /T ({names[i]}) /Rect [20 {20 + i * 30} 200 {40 + i * 30}] /F 4 /P 10 0 R /DA (/Helv 12 Tf 0 g)>>");
        }
        return pdf.Finish();
    }

    private static string Name(PdfDocument document, PdfObject? field) => PdfText.Read(document, (PdfDictionary)document.Resolve(field)!, "T")!;

    [Fact]
    public void AFontOfTheSameNameIsRenamedAndTheCopiedFieldsFollow()
    {
        var first = PdfDocument.Open(Sheet("Helvetica", "a"));
        var second = PdfDocument.Open(Sheet("Courier", "b"));
        var merged = PageAssembly.Merge([new MergeSource(first), new MergeSource(second)]);
        var bytes = merged.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);

        var again = PdfDocument.Open(bytes);
        var fonts = again.Dict(again.Dict(again.Dict(again.Catalog, "AcroForm"), "DR"), "Font")!;
        Assert.Equal("Helvetica", again.Name(again.Dict(fonts, "Helv"), "BaseFont"));
        Assert.Equal("Courier", again.Name(again.Dict(fonts, "Helv_2"), "BaseFont"));

        var form = PdfForm.Read(again);
        Assert.Contains("/Helv 12 Tf", form.Find("a")!.DefaultAppearance);
        Assert.Contains("/Helv_2 12 Tf", form.Find("b")!.DefaultAppearance);

        form.SetValue("b", "typed");
        var widget = form.Find("b")!.Widgets[0].Dictionary;
        var appearance = (PdfStream)again.Resolve(again.Dict(widget, "AP")!["N"])!;
        Assert.Equal("Courier", again.Name(again.Dict(again.Dict(again.Dict(appearance.Dictionary, "Resources"), "Font"), "F1"), "BaseFont"));
    }

    [Fact]
    public void AFontThatIsTheSameInBothFilesIsNotCopiedTwice()
    {
        var merged = PageAssembly.Merge([
            new MergeSource(PdfDocument.Open(Sheet("Helvetica", "a"))),
            new MergeSource(PdfDocument.Open(Sheet("Helvetica", "b")))]);
        var fonts = merged.Dict(merged.Dict(merged.Dict(merged.Catalog, "AcroForm"), "DR"), "Font")!;
        Assert.Single(fonts.Entries);
    }

    [Fact]
    public void CalculationOrderIsCarriedThroughImport()
    {
        byte[] file = Sheet("Helvetica", "a b", co: "/CO [21 0 R 20 0 R]");
        var merged = PageAssembly.Merge([new MergeSource(PdfDocument.Open(file)), new MergeSource(PdfDocument.Open(file))]);
        var bytes = merged.SaveRewrite();
        IntegrationFiles.ReadBack(bytes);

        var again = PdfDocument.Open(bytes);
        var order = again.Array(again.Dict(again.Catalog, "AcroForm"), "CO")!.Items;
        Assert.Equal(["b", "a", "b_2", "a_2"], order.Select(o => Name(again, o)));
    }

    [Fact]
    public void ExtractingAPageKeepsTheCalculationOrderOfItsFieldsOnly()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 4 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [10 0 R 11 0 R] /Count 2 /MediaBox [0 0 300 300]>>");
        pdf.Obj(4, "<</Fields [20 0 R 21 0 R] /CO [21 0 R 20 0 R] /DA (/Helv 12 Tf 0 g)>>");
        pdf.Obj(10, "<</Type /Page /Parent 2 0 R /Annots [20 0 R]>>");
        pdf.Obj(11, "<</Type /Page /Parent 2 0 R /Annots [21 0 R]>>");
        pdf.Obj(20, "<</Type /Annot /Subtype /Widget /FT /Tx /T (a) /Rect [20 20 100 40] /P 10 0 R>>");
        pdf.Obj(21, "<</Type /Annot /Subtype /Widget /FT /Tx /T (b) /Rect [20 20 100 40] /P 11 0 R>>");
        var extracted = PageAssembly.Extract(PdfDocument.Open(pdf.Finish()), [1]);
        var order = extracted.Array(extracted.Dict(extracted.Catalog, "AcroForm"), "CO")!.Items;
        Assert.Equal(["b"], order.Select(o => Name(extracted, o)));
    }

    // A radio group of three buttons, one on each of three pages; the second is on.
    private static PdfDocument Radios()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 4 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [10 0 R 11 0 R 12 0 R] /Count 3 /MediaBox [0 0 300 300]>>");
        pdf.Obj(4, "<</Fields [20 0 R]>>");
        pdf.Obj(20, "<</FT /Btn /Ff 49152 /T (grp) /Kids [21 0 R 22 0 R 23 0 R] /V /1 /Opt [(One) (Two) (Three)]>>");
        for (int i = 0; i < 3; i++)
        {
            pdf.Obj(10 + i, $"<</Type /Page /Parent 2 0 R /Annots [{21 + i} 0 R]>>");
            string on = i.ToString();
            pdf.Obj(21 + i, $"<</Type /Annot /Subtype /Widget /Parent 20 0 R /Rect [20 20 40 40] /P {10 + i} 0 R /AS {(i == 1 ? "/1" : "/Off")} /AP <</N <</{on} 30 0 R /Off 31 0 R>>>>>>");
        }
        pdf.Stream(30, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "");
        pdf.Stream(31, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "");
        return PdfDocument.Open(pdf.Finish());
    }

    private static PdfDictionary Group(PdfDocument document)
    {
        var fields = document.Array(document.Dict(document.Catalog, "AcroForm"), "Fields")!;
        return (PdfDictionary)document.Resolve(fields.Items[0])!;
    }

    [Fact]
    public void ExtractingOneButtonOfAGroupTrimsItsOptions()
    {
        var kept = PageAssembly.Extract(Radios(), [2]);
        var group = Group(kept);
        Assert.Single(kept.Array(group, "Kids")!.Items);
        Assert.Equal(["Three"], kept.Array(group, "Opt")!.Items.Select(o => PdfText.Read(kept, o)));
        IntegrationFiles.ReadBack(kept.SaveRewrite());
    }

    [Fact]
    public void AValueNamingAButtonLeftBehindBecomesOff()
    {
        var left = Group(PageAssembly.Extract(Radios(), [0]));
        Assert.Equal("Off", ((PdfName)left["V"]!).Value);

        var chosen = PageAssembly.Extract(Radios(), [0, 1]);
        var group = Group(chosen);
        Assert.Equal("1", ((PdfName)group["V"]!).Value);
        Assert.Equal(["One", "Two"], chosen.Array(group, "Opt")!.Items.Select(o => PdfText.Read(chosen, o)));
    }

    [Fact]
    public void ADocumentListedTwiceGivesTwoFieldsOfItsOwn()
    {
        var source = PdfDocument.Open(IntegrationFiles.Form(2));
        var merged = PageAssembly.Merge([new MergeSource(source), new MergeSource(source)]);
        var bytes = merged.SaveRewrite();
        var texts = IntegrationFiles.ReadBack(bytes);
        Assert.Equal(4, texts.Count);

        var form = PdfForm.Read(PdfDocument.Open(bytes));
        var names = form.Fields.Select(f => f.Name).ToList();
        Assert.Equal(names.Count, names.Distinct().Count());
        form.SetValue("f1", "first");
        Assert.Null(form.Find("f1_2")!.Value);
        Assert.Equal(2, form.Find("f1_2")!.Widgets[0].PageIndex);
        Assert.Single(form.Find("f1_2")!.Widgets);
    }
}
