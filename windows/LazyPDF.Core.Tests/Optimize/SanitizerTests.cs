using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SanitizerTests
{
    private static readonly byte[] Dirty = SanitizeKit.Dirty();

    [Fact]
    public void ScanCountsEachKindAndChangesNothing()
    {
        using var document = PdfDocument.Open(Dirty);
        byte[] before = document.SaveRewrite();
        var findings = new PdfSanitizer(document).Scan();
        Assert.True(SanitizeKit.Count(findings, SanitizeItem.JavaScript) >= 5);
        Assert.Equal(1, SanitizeKit.Count(findings, SanitizeItem.LaunchActions));
        Assert.Equal(2, SanitizeKit.Count(findings, SanitizeItem.ExternalLinks));
        Assert.True(SanitizeKit.Count(findings, SanitizeItem.EmbeddedFiles) >= 1);
        Assert.Equal(2, SanitizeKit.Count(findings, SanitizeItem.Comments));
        Assert.Equal(1, SanitizeKit.Count(findings, SanitizeItem.FormData));
        Assert.Equal(2, SanitizeKit.Count(findings, SanitizeItem.Metadata));
        Assert.Equal(1, SanitizeKit.Count(findings, SanitizeItem.PieceInfo));
        Assert.Equal(1, SanitizeKit.Count(findings, SanitizeItem.Thumbnails));
        Assert.Equal(2, SanitizeKit.Count(findings, SanitizeItem.SearchIndexes));
        Assert.True(SanitizeKit.Count(findings, SanitizeItem.FilePaths) >= 1);
        Assert.Equal(1, SanitizeKit.Count(findings, SanitizeItem.PreviousVersions));
        Assert.Equal(findings.Select(f => f.Item).Order(), findings.Select(f => f.Item));
        Assert.Equal(before.Length, document.SaveRewrite().Length);
        Assert.All(findings, f => Assert.False(string.IsNullOrEmpty(OptimizeText.ItemName(f.Item))));
    }

    [Fact]
    public void RunLeavesNoMarkerInTheBytesOrTheDecodedStreams()
    {
        foreach (string marker in SanitizeKit.Markers) Assert.True(OptimizeKit.Everywhere(Dirty, marker), marker + " should be in the source");
        using var document = PdfDocument.Open(Dirty);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        foreach (string marker in SanitizeKit.Markers) Assert.False(OptimizeKit.Everywhere(result.Bytes, marker), marker);
        Assert.Equal("Visible text", OptimizeKit.PigText(result.Bytes).Trim());
        Assert.Equal(1, OptimizeKit.PigPages(result.Bytes));
        Assert.Equal(1, Encoding.Latin1.GetString(result.Bytes).Split("%%EOF").Length - 1);
        Assert.Equal(Dirty.Length, result.SizeBefore);
        Assert.Equal(result.Bytes.Length, result.SizeAfter);
        Assert.Equal(2, SanitizeKit.Count(result.Removed, SanitizeItem.Comments));
        Assert.Empty(result.Kept);
    }

    [Fact]
    public void WhatWasNotChosenStaysAndIsListedAsKept()
    {
        using var document = PdfDocument.Open(Dirty);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { JavaScript = false, Comments = false });
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "MARKERJS1"));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "MARKERNOTE"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERXMP"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERLAUNCH"));
        Assert.True(SanitizeKit.Count(result.Kept, SanitizeItem.JavaScript) >= 5);
        Assert.Equal(2, SanitizeKit.Count(result.Kept, SanitizeItem.Comments));
        Assert.Equal(0, SanitizeKit.Count(result.Removed, SanitizeItem.JavaScript));
    }

    [Fact]
    public void AltTextOfAnImageIsLeftAlone()
    {
        using var document = PdfDocument.Open(Dirty);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { Thumbnails = false });
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "MARKERALT"));
    }

    [Fact]
    public void ScriptChainedAfterAGoToIsCutOutOfTheChain()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R]>>");
        pdf.Obj(4, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /A <</S /GoTo /D [3 0 R /Fit] /Next [<</S /JavaScript /JS (MARKERJS1)>> <</S /Named /N /NextPage>>]>>>>");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERJS1"));
        using var after = PdfDocument.Open(result.Bytes);
        var link = (PdfDictionary)after.Resolve(after.Array(after.Pages[0].Dictionary, "Annots")!.Items[0])!;
        var action = after.Dict(link, "A")!;
        Assert.Equal("GoTo", after.Name(action, "S"));
        Assert.Single(after.Array(action, "Next")!.Items);
    }

    [Fact]
    public void FilePathsAreCutToTheFileNameWhenTheAttachmentStays()
    {
        using var document = PdfDocument.Open(Dirty);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions { EmbeddedFiles = false });
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "MARKERATTACH"));
        Assert.True(OptimizeKit.Everywhere(result.Bytes, "MARKERPATH.txt"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "Users"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "bob"));
    }

    [Fact]
    public void FormValuesAreClearedAndTheFieldsStay()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R 5 0 R] /DA (/Helv 12 Tf 0 g) /DR <</Font <</Helv 6 0 R>>>>>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R 5 0 R]>>");
        pdf.Obj(4, "<</Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (MARKERFORM) /DV (MARKERDEFAULT) /Rect [10 100 150 120] /P 3 0 R>>");
        pdf.Obj(5, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [10 50 30 70] /P 3 0 R /AP <</N <</Yes 7 0 R /Off 8 0 R>>>>>>");
        pdf.Obj(6, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "0 0 20 20 re f");
        pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "");
        using var document = PdfDocument.Open(pdf.Finish());
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.Equal(2, SanitizeKit.Count(result.Removed, SanitizeItem.FormData));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERFORM"));
        Assert.False(OptimizeKit.Everywhere(result.Bytes, "MARKERDEFAULT"));
        using var after = PdfDocument.Open(result.Bytes);
        var form = PdfForm.Read(after);
        Assert.Equal(2, form.Fields.Count);
        Assert.True(string.IsNullOrEmpty(form.Find("name")!.Value));
        Assert.False(form.Find("agree")!.IsChecked);
    }

    [Fact]
    public void BlankingAFieldTakesEveryCopyOfTheEnteredValue()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm <</Fields [4 0 R 5 0 R]>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 200]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Annots [4 0 R 5 0 R]>>");
        pdf.Obj(4, "<</Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [10 50 30 70] /P 3 0 R /AP <</N <</Yes 7 0 R>>>>>>");
        pdf.Obj(5, "<</Type /Annot /Subtype /Widget /FT /Ch /T (pick) /Opt [(a) (b) (c)] /V (c) /I [2] /Rect [10 100 80 140] /P 3 0 R>>");
        pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 20 20]", "0 0 20 20 re f");
        using var document = PdfDocument.Open(pdf.Finish());
        foreach (var field in PdfForm.Read(document).Fields) SanitizeData.Blank(document, field.Dictionary);
        byte[] saved = document.SaveRewrite();
        foreach (string key in new[] { "/V", "/AS", "/I ", "/AP" }) Assert.False(OptimizeKit.Everywhere(saved, key), key);
    }

    [Fact]
    public void ARunOnNothingToRemoveJustRewrites()
    {
        using var document = PdfDocument.Open(TestPdf.Simple(2));
        var findings = new PdfSanitizer(document).Scan();
        Assert.Empty(findings);
        var result = new PdfSanitizer(document).Run(new SanitizeOptions());
        Assert.Empty(result.Removed);
        Assert.Equal(2, OptimizeKit.PigPages(result.Bytes));
    }
}
