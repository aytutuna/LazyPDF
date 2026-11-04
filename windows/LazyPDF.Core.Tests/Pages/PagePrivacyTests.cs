using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// Nothing of a page that was taken out may be left in what is written: the marker of each page appears
// in its content, in a form it draws, in a note on it, and in a resource the whole file lists.
public class PagePrivacyTests
{
    private static string Marker(int page) => $"MARKER-{page}-{page * 7919}";

    /// <summary>
    /// Three pages (objects 10 to 12). With <paramref name="shared"/> the root's /Resources lists all
    /// three forms, which is how some writers give every page everything; without it each page lists
    /// its own. A link on page 1 goes to page 2; page 3 has a bookmark, a named destination and a bead.
    /// </summary>
    private static byte[] Source(bool shared = true)
    {
        string Own(int page) => shared ? "" : $"/Resources <</Font <</F1 3 0 R>> /XObject <</Fm{page} {19 + page} 0 R>>>>";
        var pdf = new TestPdf()
            .Obj(1, "<</Type /Catalog /Pages 2 0 R /Outlines 30 0 R /Dests <</two [11 0 R /Fit]>> /Names <</Dests <</Names [(three) [12 0 R /Fit]]>>>> /Threads [40 0 R]>>")
            .Obj(2, "<</Type /Pages /Kids [10 0 R 11 0 R 12 0 R] /Count 3 /MediaBox [0 0 200 200] " + (shared ? "/Resources <</Font <</F1 3 0 R>> /XObject <</Fm1 20 0 R /Fm2 21 0 R /Fm3 22 0 R>>>>" : "") + ">>")
            .Obj(3, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>")
            .Obj(10, "<</Type /Page /Parent 2 0 R /Contents 13 0 R /Annots [50 0 R 51 0 R] " + Own(1) + ">>")
            .Obj(11, "<</Type /Page /Parent 2 0 R /Contents 14 0 R /Annots [52 0 R] " + Own(2) + ">>")
            .Obj(12, "<</Type /Page /Parent 2 0 R /Contents 15 0 R /B [41 0 R] " + Own(3) + ">>")
            .Stream(13, "", $"BT /F1 12 Tf ({Marker(1)}) Tj ET /Fm1 Do")
            .Stream(14, "", $"BT /F1 12 Tf ({Marker(2)}) Tj ET /Fm2 Do")
            .Stream(15, "", $"BT /F1 12 Tf ({Marker(3)}) Tj ET /Fm3 Do")
            .Stream(20, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources <<>>", $"BT ({Marker(1)}-form) Tj ET")
            .Stream(21, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", $"BT ({Marker(2)}-form) Tj ET")
            .Stream(22, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", $"BT ({Marker(3)}-form) Tj ET")
            .Obj(30, "<</Type /Outlines /First 31 0 R /Last 31 0 R /Count 1>>")
            .Obj(31, "<</Title (Chapter) /Parent 30 0 R /Dest [12 0 R /Fit]>>")
            .Obj(40, "<</Type /Thread /F 41 0 R>>")
            .Obj(41, "<</Type /Bead /T 40 0 R /N 41 0 R /V 41 0 R /P 12 0 R /R [0 0 10 10]>>")
            .Obj(50, "<</Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [11 0 R /Fit]>>")
            .Obj(51, $"<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents ({Marker(1)}-note)>>")
            .Obj(52, $"<</Type /Annot /Subtype /Text /Rect [0 0 10 10] /Contents ({Marker(2)}-note)>>");
        return pdf.Finish();
    }

    /// <summary>The marker written anywhere in the file: in the bytes, in a stream once decoded, in an object once read.</summary>
    private static bool Holds(byte[] file, string marker)
    {
        if (Encoding.Latin1.GetString(file).Contains(marker)) return true;
        var document = PdfDocument.Open(file);
        foreach (int number in document.ObjectNumbers)
        {
            switch (document.Get(number))
            {
                case PdfStream stream when Encoding.Latin1.GetString(document.Data(stream)).Contains(marker):
                case PdfDictionary or PdfArray when document.Get(number)!.ToString()!.Contains(marker):
                    return true;
            }
        }
        return false;
    }

    private static void AssertOnly(byte[] file, params int[] pages)
    {
        foreach (int page in new[] { 1, 2, 3 })
        {
            Assert.Equal(pages.Contains(page), Holds(file, Marker(page)));
        }
    }

    [Fact]
    public void TheMarkersAreFoundWhereTheyAre()
    {
        AssertOnly(PdfDocument.Open(Source()).SaveRewrite(), 1, 2, 3);
        AssertOnly(PdfDocument.Open(Source()).SaveRewrite(new PdfSaveOptions(UseObjectStreams: true)), 1, 2, 3);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void AnExtractedPartHoldsOnlyItsOwnPages(bool packed)
    {
        var options = new PdfSaveOptions(UseObjectStreams: packed);
        AssertOnly(PageAssembly.Extract(PdfDocument.Open(Source()), [0]).SaveRewrite(options), 1);
        AssertOnly(PageAssembly.Extract(PdfDocument.Open(Source()), [1]).SaveRewrite(options), 2);
        AssertOnly(PageAssembly.Extract(PdfDocument.Open(Source()), [2]).SaveRewrite(options), 3);
        AssertOnly(PageAssembly.Extract(PdfDocument.Open(Source()), [2, 0]).SaveRewrite(options), 1, 3);
    }

    [Fact]
    public void EverySplitPartHoldsOnlyItsOwnPages()
    {
        var parts = PageAssembly.SplitEvery(PdfDocument.Open(Source()), 1);
        Assert.Equal(3, parts.Count);
        for (int i = 0; i < 3; i++) AssertOnly(parts[i].SaveRewrite(), i + 1);
    }

    [Fact]
    public void ANewDocumentHasNothingOfTheSourcesStructure()
    {
        var part = PageAssembly.Extract(PdfDocument.Open(Source()), [0]);
        var again = PdfDocument.Open(part.SaveRewrite());
        foreach (string key in new[] { "Outlines", "Dests", "Names", "Threads", "PageLabels", "StructTreeRoot", "OpenAction" })
        {
            Assert.False(again.Catalog.ContainsKey(key), key);
        }
        Assert.Single(again.Pages);
        Assert.Empty(again.Repairs);
        Assert.Equal(1, again.ObjectNumbers.Count(n => again.Get(n) is PdfDictionary d && again.Name(d, "Type") == "Page"));
    }

    [Fact]
    public void AResourceThePageNeverMentionsIsNotCopied()
    {
        var part = PageAssembly.Extract(PdfDocument.Open(Source()), [0]);
        var again = PdfDocument.Open(part.SaveRewrite());
        var forms = again.Dict(again.Pages[0].Resources, "XObject")!;
        Assert.Equal(["Fm1"], forms.Entries.Select(e => e.Key));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ADeletedPageLeavesNothingInARewrite(bool packed)
    {
        var document = PdfDocument.Open(Source(shared: false));
        PageOperations.Delete(document, [1]);
        AssertOnly(document.SaveRewrite(new PdfSaveOptions(UseObjectStreams: packed)), 1, 3);
        document = PdfDocument.Open(Source(shared: false));
        PageOperations.Delete(document, [2]);
        AssertOnly(document.SaveRewrite(new PdfSaveOptions(UseObjectStreams: packed)), 1, 2);
    }

    [Fact]
    public void ADeleteAfterAnEditSessionCommitStillLeavesNothingInACompactSave()
    {
        var session = PdfEditSession.Open(Source(shared: false));
        PageOperations.Delete(session.Document, [0, 2]);
        Assert.True(session.Commit("Delete"));
        string path = Path.Combine(Path.GetTempPath(), $"lazypdf-privacy-{Guid.NewGuid():N}.pdf");
        try
        {
            session.SaveCompact(path);
            AssertOnly(File.ReadAllBytes(path), 2);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void TheIncrementalFileStillHoldsWhatWasDeletedAsAnyHistoryDoes()
    {
        var session = PdfEditSession.Open(Source());
        PageOperations.Delete(session.Document, [1]);
        Assert.True(session.Commit("Delete"));
        Assert.True(Holds(session.Current.ToArray(), Marker(2)));
    }
}
