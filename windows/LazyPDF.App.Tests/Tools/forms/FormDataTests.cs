using System.Text;
using System.Text.Json;
using LazyPDF.App.Tools.Forms;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The four data formats of the Forms tool against a form read by Core.
public sealed class FormDataTests
{
    private static PdfForm Filled()
    {
        var form = PdfForm.Read(PdfDocument.Open(FormPdfs.Standard()), new FakeFonts());
        form.SetValues([new("name", "Ada"), new("agree", "Yes"), new("city", "IZ")]);
        form.SetChoices("langs", ["Turkish", "German"]);
        return PdfForm.Read(form.Document, new FakeFonts());
    }

    private static PdfForm Empty() => PdfForm.Read(PdfDocument.Open(FormPdfs.Standard()), new FakeFonts());

    [Theory]
    [InlineData("a.fdf", DataFormat.Fdf)]
    [InlineData("a.XFDF", DataFormat.Xfdf)]
    [InlineData("b.csv", DataFormat.Csv)]
    [InlineData("c.json", DataFormat.Json)]
    public void TheFormatComesFromTheExtension(string path, DataFormat expected) => Assert.Equal(expected, FormData.FormatOf(path));

    [Fact]
    public void AnOtherExtensionHasNoFormat() => Assert.Null(FormData.FormatOf("notes.txt"));

    [Theory]
    [InlineData(DataFormat.Fdf)]
    [InlineData(DataFormat.Xfdf)]
    [InlineData(DataFormat.Csv)]
    [InlineData(DataFormat.Json)]
    public void WhatIsExportedFillsAnEmptyCopy(DataFormat format)
    {
        byte[] data = FormData.Export(Filled(), format, "form.pdf");
        var target = Empty();

        var result = FormData.Import(target, format, data, out int rows);
        var after = PdfForm.Read(target.Document, new FakeFonts());

        Assert.Equal(1, rows);
        Assert.Empty(result.UnknownFields);
        Assert.Equal("Ada", after.Find("name")!.Value);
        Assert.Equal("Yes", after.Find("agree")!.Value);
        Assert.Equal("IZ", after.Find("city")!.Value);
        Assert.Equal(["Turkish", "German"], after.Find("langs")!.Selected);
    }

    [Fact]
    public void ACsvFileStartsWithAByteOrderMarkForExcel()
    {
        byte[] data = FormData.Export(Filled(), DataFormat.Csv, "form.pdf");

        Assert.Equal(Encoding.UTF8.GetPreamble(), data[..3]);
        Assert.StartsWith("name,", Encoding.UTF8.GetString(data).TrimStart('﻿'));
    }

    [Fact]
    public void ACsvWithSeveralRowsFillsFromTheFirstAndSaysSo()
    {
        var form = Empty();
        string csv = "name;code\r\nAda;1234\r\nGrace;5678\r\n";

        var result = FormData.Import(form, DataFormat.Csv, Encoding.UTF8.GetBytes(csv), out int rows);

        Assert.Equal(2, rows);
        Assert.Equal(2, result.Filled);
        Assert.Equal("Ada", PdfForm.Read(form.Document, new FakeFonts()).Find("name")!.Value);
    }

    [Fact]
    public void ACsvSavedInTheAnsiCodePageStillReadsItsTurkishLetters()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var form = Empty();
        byte[] data = Encoding.GetEncoding(1254).GetBytes("name;code\r\n\u00c7elik;12\r\n");

        FormData.Import(form, DataFormat.Csv, data, out _);

        Assert.Equal("\u00c7elik", PdfForm.Read(form.Document, new FakeFonts()).Find("name")!.Value);
    }

    [Fact]
    public void ACsvCellInQuotesKeepsItsSeparatorsAndLineBreaks()
    {
        var table = FormData.ParseCsv("a,b\n\"x, \"\"y\"\"\nz\",2\n");

        Assert.Equal(2, table.Count);
        Assert.Equal("x, \"y\"\nz", table[1][0]);
        Assert.Equal("2", table[1][1]);
    }

    [Fact]
    public void AColumnNoFieldHasIsReportedNotFatal()
    {
        var result = FormData.Import(Empty(), DataFormat.Csv, Encoding.UTF8.GetBytes("name,nothing\nAda,x\n"), out _);

        Assert.Equal(["nothing"], result.UnknownFields);
        Assert.Equal(1, result.Filled);
    }

    [Fact]
    public void ACsvWithoutADataRowIsRefused() =>
        Assert.Throws<FormatException>(() => FormData.Import(Empty(), DataFormat.Csv, Encoding.UTF8.GetBytes("name,code\n"), out _));

    [Fact]
    public void JsonTakesNumbersBooleansAndArrays()
    {
        var form = Empty();
        string json = """{ "name": "Grace", "code": 42, "agree": true, "langs": ["English", "German"] }""";

        FormData.Import(form, DataFormat.Json, Encoding.UTF8.GetBytes(json), out _);
        var after = PdfForm.Read(form.Document, new FakeFonts());

        Assert.Equal("Grace", after.Find("name")!.Value);
        Assert.Equal("42", after.Find("code")!.Value);
        Assert.True(after.Find("agree")!.IsChecked);
        Assert.Equal(["English", "German"], after.Find("langs")!.Selected);
    }

    [Fact]
    public void JsonThatIsNotAnObjectIsRefused() =>
        Assert.Throws<JsonException>(() => FormData.Import(Empty(), DataFormat.Json, Encoding.UTF8.GetBytes("[1, 2]"), out _));

    [Fact]
    public void BrokenFdfIsRefusedAsDamaged() =>
        Assert.Throws<PdfReadException>(() => FormData.Import(Empty(), DataFormat.Fdf, Encoding.ASCII.GetBytes("not an fdf"), out _));

    [Fact]
    public void JsonLeavesOutButtonsAndSignatures()
    {
        var document = PdfDocument.Open(FormPdfs.Standard());
        var form = PdfForm.Read(document, new FakeFonts());
        form.AddField(new FieldSpec(FieldKind.PushButton, "send", 0, new PdfRect(300, 640, 400, 664)) { Caption = "Send" });
        form.AddField(new FieldSpec(FieldKind.Signature, "sign", 0, new PdfRect(300, 560, 500, 600)));

        using var json = JsonDocument.Parse(FormData.Export(PdfForm.Read(document, new FakeFonts()), DataFormat.Json, "form.pdf"));

        Assert.False(json.RootElement.TryGetProperty("send", out _));
        Assert.False(json.RootElement.TryGetProperty("sign", out _));
        Assert.True(json.RootElement.TryGetProperty("name", out _));
    }
}
