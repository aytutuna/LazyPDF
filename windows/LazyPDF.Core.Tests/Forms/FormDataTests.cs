using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.AnnotationFixtures;

namespace LazyPDF.Core.Tests;

public class FormDataTests
{
    private static PdfForm Open(IFontSource? fonts = null) => PdfForm.Read(FormFixtures.Open(), fonts);

    private static IReadOnlyDictionary<string, string> Values(FdfFile fdf) => fdf.FlatFields().ToDictionary(
        p => p.Key,
        p => fdf.Resolve(p.Value) switch { PdfString s => PdfText.Decode(s.Bytes), PdfName n => n.Value, PdfArray a => string.Join("|", a.Items.Select(i => PdfText.Decode(((PdfString)i).Bytes))), _ => "?" });

    [Fact]
    public void FdfCarriesValuesButNotButtonsOrSignatures()
    {
        var form = Open();
        form.SetValues([new("name", "Ada"), new("agree", "Yes"), new("choice", "b"), new("city", "Izmir"), new("langs", "English; German")]);

        var fdf = PdfFdf.Read(PdfFdf.Write(form.ExportFdf("form.pdf")));

        Assert.Equal("form.pdf", fdf.FileName);
        var values = Values(fdf);
        Assert.Equal("Ada", values["name"]);
        Assert.Equal("Yes", values["agree"]);
        Assert.Equal("b", values["choice"]);
        Assert.Equal("IZ", values["city"]);
        Assert.Equal("English|German", values["langs"]);
        Assert.Equal("", values["bio"]);
        Assert.False(values.ContainsKey("sig"));
        Assert.Equal(8, values.Count);
    }

    [Fact]
    public void FdfOfNestedNamesIsNested()
    {
        var form = PdfForm.Read(AnnotationFixtures.Blank());
        form.AddField(new FieldSpec(FieldKind.Text, "person.first", 0, new PdfRect(50, 700, 250, 720)) { Value = "Ada" });

        var fdf = form.ExportFdf();

        var person = Assert.Single(fdf.Fields);
        Assert.Equal("person", person.Name);
        Assert.Equal("first", Assert.Single(person.Kids).Name);
        Assert.Equal("Ada", Values(PdfFdf.Read(PdfFdf.Write(fdf)))["person.first"]);
    }

    [Fact]
    public void FdfAndXfdfFillAnotherCopyOfTheForm()
    {
        var source = Open();
        source.SetValues([new("name", "Grace"), new("agree", "Yes"), new("choice", "a"), new("code", "42"), new("langs", "Greek; Latin")]);
        var fdf = source.ExportFdf();

        foreach (var carried in new[] { PdfFdf.Read(PdfFdf.Write(fdf)), PdfXfdf.Read(PdfXfdf.Write(fdf)) })
        {
            var target = Open();
            var result = target.ImportFdf(carried);

            Assert.Empty(result.UnknownFields);
            Assert.Equal("Grace", target.Find("name")!.Value);
            Assert.True(target.Find("agree")!.IsChecked);
            Assert.Equal("a", target.Find("choice")!.Value);
            Assert.Equal("42", target.Find("code")!.Value);
            Assert.Equal(["Greek", "Latin"], target.Find("langs")!.Selected);
            Assert.Equal("Grace", FormFixtures.Drawn(target.Document, target.Find("name")!.Widgets[0]));
        }
    }

    [Fact]
    public void ImportReportsNamesTheFormDoesNotHave()
    {
        var fdf = new FdfFile();
        fdf.Fields.Add(new FdfField("name", PdfText.ToObject("x"), []));
        fdf.Fields.Add(new FdfField("ghost", PdfText.ToObject("y"), []));

        var result = Open().ImportFdf(fdf);

        Assert.Equal(["ghost"], result.UnknownFields);
        Assert.Equal(1, result.Filled);
    }

    [Fact]
    public void TurkishValuesTravelThroughFdf()
    {
        var fdf = new FdfFile();
        fdf.Fields.Add(new FdfField("name", PdfText.ToObject("Çağrı Şen"), []));
        var target = Open(new ArialSource());

        target.ImportFdf(PdfFdf.Read(PdfFdf.Write(fdf)));

        Assert.Equal("Çağrı Şen", target.Find("name")!.Value);
        Assert.Equal("Çağrı Şen", FormFixtures.Drawn(target.Document, target.Find("name")!.Widgets[0]));
    }

    [Fact]
    public void CsvExportIsAHeaderAndARow()
    {
        var form = Open();
        form.SetValues([new("name", "Lovelace, Ada"), new("bio", "line one\nline \"two\""), new("langs", "English; German")]);

        string csv = form.ExportCsv();

        var rows = FormCsv.Read(csv);
        Assert.Equal(2, rows.Count);
        Assert.Equal(["name", "bio", "agree", "choice", "city", "langs", "code", "secret"], rows[0]);
        Assert.Equal("Lovelace, Ada", rows[1][0]);
        Assert.Equal("line one\nline \"two\"", rows[1][1]);
        Assert.Equal("Off", rows[1][2]);
        Assert.Equal("English; German", rows[1][5]);
        Assert.EndsWith("\r\n", csv);
    }

    [Fact]
    public void CsvReadingFollowsRfc4180AndSpreadsheetHabits()
    {
        var rows = FormCsv.Read("﻿a;b;c\r\n1;\"x;y\";\r\n\r\n\"two\nlines\";\"say \"\"hi\"\"\";3\r\n");

        Assert.Equal(3, rows.Count);
        Assert.Equal(["a", "b", "c"], rows[0]);
        Assert.Equal(["1", "x;y", ""], rows[1]);
        Assert.Equal(["two\nlines", "say \"hi\"", "3"], rows[2]);
        Assert.Equal([["a", "b"], ["1", "2"]], FormCsv.Read("a\tb\n1\t2"));
        Assert.Equal([["only"]], FormCsv.Read("only"));
        Assert.Empty(FormCsv.Read(""));
    }

    [Fact]
    public void OnePdfPerCsvRow()
    {
        var bytes = FormFixtures.Standard();
        var bulk = BulkFill.Create(bytes, "name,agree,city,nothing\r\nAda,yes,Izmir,x\r\n\"Lovelace, A\",no,Bursa,y\r\n");

        Assert.Equal(2, bulk.Rows);
        Assert.Equal(["nothing"], bulk.UnmatchedColumns);

        var first = PdfDocument.Open(bulk.Fill(0));
        var second = PdfDocument.Open(bulk.Fill(1));
        var a = PdfForm.Read(first);
        var b = PdfForm.Read(second);
        Assert.Equal("Ada", a.Find("name")!.Value);
        Assert.True(a.Find("agree")!.IsChecked);
        Assert.Equal("IZ", a.Find("city")!.Value);
        Assert.Equal("Lovelace, A", b.Find("name")!.Value);
        Assert.False(b.Find("agree")!.IsChecked);
        Assert.Equal("Lovelace, A", FormFixtures.Drawn(second, b.Find("name")!.Widgets[0]));
        Assert.Empty(first.Repairs);
        foreach (var file in new[] { bulk.Fill(0), bulk.Fill(1) })
        {
            using var pig = UglyToad.PdfPig.PdfDocument.Open(file);
            Assert.Equal(1, pig.NumberOfPages);
        }
        Assert.Null(PdfForm.Read(PdfDocument.Open(bytes)).Find("name")!.Value);
    }

    [Fact]
    public void BulkRowsCanBeFlattenedAndHoldTurkishText()
    {
        var bulk = BulkFill.Create(FormFixtures.Standard(), "name;city\nÇağrı Şen;Bursa\n", new ArialSource());

        var document = PdfDocument.Open(bulk.Fill(0, flatten: true));

        Assert.Null(document.Dict(document.Catalog, "AcroForm"));
        using var pig = UglyToad.PdfPig.PdfDocument.Open(bulk.Fill(0, flatten: true));
        Assert.Contains("Çağrı Şen", pig.GetPage(1).Text);
    }

    [Fact]
    public void BulkFillRefusesDynamicXfa()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [] /XFA [(template) 12 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R>>");

        Assert.Throws<PdfReadException>(() => BulkFill.Create(pdf.Finish(), "a\n1\n"));
    }
}
