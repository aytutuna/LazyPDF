using System.Text;
using LazyPDF.App.Tools.PdfUa;
using LazyPDF.App.Tools.Standards;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The PDF/UA panel's rows and the offer to mark, against Core's checker and marker.
public sealed class PdfUaRowsTests
{
    // One tagged figure with a description, a title and a language, and nothing that marking writes itself.
    private static byte[] Markable()
    {
        var pdf = new MemoryStream();
        var offsets = new List<long>();
        void Put(string text) => pdf.Write(Encoding.Latin1.GetBytes(text));
        void Obj(string body)
        {
            offsets.Add(pdf.Position);
            Put($"{offsets.Count} 0 obj\n{body}\nendobj\n");
        }

        const string draw = "/Figure <</MCID 0>> BDC 0 0 1 rg 20 20 100 100 re f EMC";
        Put("%PDF-1.7\n");
        Obj("<</Type /Catalog /Pages 2 0 R /MarkInfo <</Marked true>> /Lang (en-US) /StructTreeRoot 5 0 R>>");
        Obj("<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300]>>");
        Obj("<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources <<>> /StructParents 0 /Tabs /S>>");
        Obj($"<</Length {draw.Length}>>\nstream\n{draw}\nendstream");
        Obj("<</Type /StructTreeRoot /K 6 0 R /ParentTree 8 0 R>>");
        Obj("<</Type /StructElem /S /Document /P 5 0 R /K 7 0 R>>");
        Obj("<</Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0 /Alt (A blue square)>>");
        Obj("<</Nums [0 [7 0 R]]>>");
        Obj("<</Title (Square) /Creator (Test) /Producer (Test)>>");
        long xref = pdf.Position;
        Put($"xref\n0 {offsets.Count + 1}\n0000000000 65535 f \n");
        foreach (long offset in offsets) Put($"{offset:D10} 00000 n \n");
        Put($"trailer\n<</Size {offsets.Count + 1} /Root 1 0 R /Info 9 0 R /ID [<0102030405060708090A0B0C0D0E0F10> <0102030405060708090A0B0C0D0E0F10>]>>\nstartxref\n{xref}\n%%EOF\n");
        return pdf.ToArray();
    }

    [Fact]
    public void RowsNameTheMatterhornConditionAndTheClause()
    {
        var rows = IssueRow.Group(
        [
            new PdfUaIssue("06-002", "14289-1 7.1", PdfAText.Catalog, "The XMP metadata does not have pdfuaid:part with the value 1."),
            new PdfUaIssue("13-004", "14289-1 7.3", PdfAText.PageName(2), "A Figure element has neither /Alt nor /ActualText."),
            new PdfUaIssue("13-004", "14289-1 7.3", PdfAText.PageName(4), "A Figure element has neither /Alt nor /ActualText."),
        ]);

        Assert.Equal(2, rows.Count);
        Assert.Equal("Matterhorn 06-002, ISO 14289-1 clause 14289-1 7.1", rows[0].Clause);
        Assert.Equal("Page 2, and 1 more", rows[1].Where);
        Assert.False(rows[0].HasPlaces);
        Assert.Equal("Go to page 2", rows[1].PlaceText);
    }

    [Fact]
    public void AnUntaggedFileFailsAndCannotBeMarked()
    {
        using var document = PdfDocument.Open(Pdfs.Text());

        var outcome = UaOutcome.Of(document, CancellationToken.None);

        Assert.False(outcome.Report.IsValid);
        Assert.False(outcome.CanMark);
        Assert.StartsWith("Does not pass the checks for PDF/UA-1. Conditions broken: ", outcome.Verdict(3));
        Assert.Equal("Fails PDF/UA-1 checks.", outcome.Status);
    }

    [Fact]
    public void AFileThatLacksOnlyTheIdentifierCanBeMarkedAndThenPasses()
    {
        var bytes = Markable();
        using var document = PdfDocument.Open(bytes);

        var outcome = UaOutcome.Of(document, CancellationToken.None);

        Assert.False(outcome.Report.IsValid);
        Assert.True(outcome.CanMark);
        Assert.All(outcome.Report.Issues, i => Assert.Contains(i.Condition, new[] { "06-001", "06-002", "06-003", "07-001" }));

        using var marked = PdfDocument.Open(bytes);
        Assert.True(PdfUaValidator.Mark(marked, DateTimeOffset.UnixEpoch).Marked);
        var after = UaOutcome.Of(PdfDocument.Open(marked.SaveIncremental()), CancellationToken.None);
        Assert.True(after.Report.IsValid, string.Join("; ", after.Report.Issues.Select(i => i.Condition + " " + i.Message)));
        Assert.False(after.CanMark);
        Assert.Equal("Passes Lazy PDF's checks for PDF/UA-1.", after.Verdict(0));
    }
}
