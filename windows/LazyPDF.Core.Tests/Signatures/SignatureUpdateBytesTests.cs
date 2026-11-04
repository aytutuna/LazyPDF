using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>What an update's bytes and tables say beyond the objects they define: the trailer, the page list, entries that need repair, odd numbers and unlisted objects.</summary>
public class SignatureUpdateBytesTests
{
    private const string Evil = "BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET";
    private const string OpenAction = "<</Type /Catalog /Pages 2 0 R /OpenAction <</S /JavaScript /JS (x)>>>>";

    private static SignatureReport Check(byte[] file) => SignatureKit.Verify(file)[0];

    private static void AssertNotAllowed(byte[] file, SignatureChangeKind? kind = null)
    {
        var report = Check(file);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        if (kind is { } k) Assert.Contains(report.Changes.NotAllowed, c => c.Kind == k);
    }

    // An update with the given trailer entries in place of /Root.
    private static byte[] AppendTrailer(byte[] file, string trailer, params (int Number, string Body)[] objects)
    {
        var document = PdfDocument.Open(file);
        var text = new StringBuilder("\n");
        var offsets = new List<(int Number, long Offset)>();
        foreach (var (number, body) in objects)
        {
            offsets.Add((number, file.Length + text.Length));
            text.Append($"{number} 0 obj\n{body}\nendobj\n");
        }
        long xref = file.Length + text.Length;
        text.Append("xref\n0 1\n0000000000 65535 f \n");
        foreach (var (number, offset) in offsets.OrderBy(o => o.Number)) text.Append($"{number} 1\n{offset:D10} 00000 n \n");
        int size = Math.Max(document.NextObjectNumber, offsets.Select(o => o.Number + 1).DefaultIfEmpty().Max());
        text.Append($"trailer\n<</Size {size} {trailer}{Identity(document)} /Prev {document.StartXref}>>\nstartxref\n{xref}\n%%EOF\n");
        return [.. file, .. TestPdf.Latin(text.ToString())];
    }

    private static string StreamBody(string data) => $"<</Length {data.Length}>>\nstream\n{data}\nendstream";

    // ---- the trailer

    [Theory]
    [InlineData("/Root <</Type /Catalog /Pages 2 0 R /OpenAction <</S /JavaScript /JS (x)>>>>", true)]
    [InlineData("/Root 1 3 R", false)]
    [InlineData("/Root 20 0 R /Root 1 0 R", false)]
    public void A_final_trailer_that_names_another_catalog_is_a_change_however_it_is_written(string root, bool direct)
    {
        byte[] before = TestPdf.WithPages(1).Finish(direct ? "/Root <</Type /Catalog /Pages 2 0 R>>" : "/Root 1 0 R");

        byte[] after = AppendTrailer(before, root, (20, OpenAction));

        Assert.Contains(SignatureOverlapTests.Compare(before, after, 1).NotAllowed, c => c.Kind == SignatureChangeKind.Unreadable);
    }

    [Fact]
    public void An_information_dictionary_named_with_another_generation_is_a_change()
    {
        var pdf = TestPdf.WithPages(1);
        pdf.Obj(5, "<</Title (x)>>");
        byte[] before = pdf.Finish("/Root 1 0 R /Info 5 0 R");

        byte[] after = AppendTrailer(before, "/Root 1 0 R /Info 5 3 R");

        Assert.False(SignatureOverlapTests.Compare(before, after, 1).AllAllowed);
    }

    // ---- the page list

    [Fact]
    public void A_page_object_the_repair_scan_adds_to_the_document_is_a_change()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R>>");
        pdf.Stream(4, "", "BT ET");
        byte[] before = pdf.Finish();
        byte[] after = SignatureRoleTests.AppendRaw(before, (30, "<</Type /Page /Parent 2 0 R /Contents 31 0 R>>"), (31, StreamBody(Evil)));

        Assert.Equal(2, PdfDocument.Open(after).Pages.Count);
        Assert.Contains(SignatureOverlapTests.Compare(before, after, 1).NotAllowed, c => c.Kind == SignatureChangeKind.Unreadable);
    }

    // ---- bytes the update adds to the signed ones

    // The signed bytes end inside a comment that looks like the file's last startxref line, with an object open above it.
    private static byte[] OpenObject(out long xref)
    {
        var pdf = new TestPdf();
        var starts = new long[5];
        starts[1] = pdf.Position;
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        starts[2] = pdf.Position;
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        starts[3] = pdf.Position;
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents [4 0 R 9 0 R]>>");
        starts[4] = pdf.Position;
        pdf.Stream(4, "", "BT ET");
        xref = pdf.Position;
        string head = "xref\n0 10\n0000000000 65535 f \n"
            + string.Concat(Enumerable.Range(1, 4).Select(n => $"{starts[n]:D10} 00000 n \n"))
            + string.Concat(Enumerable.Repeat("0000000000 00000 f \n", 4));
        const string trailer = "trailer\n<</Size 10 /Root 1 0 R>>\n";
        long open = xref + head.Length + 20 + trailer.Length;
        pdf.Write($"{head}{open:D10} 00000 n \n{trailer}9 0 obj\n<</Length {Evil.Length}>>\n%startxref {xref}\n%%EOF\n");
        return pdf.FinishWithoutXref();
    }

    [Fact]
    public void A_dictionary_the_signed_bytes_leave_open_can_become_a_stream()
    {
        byte[] before = OpenObject(out long xref);
        string closing = $"stream\n{Evil}\nendstream\nendobj\n";
        long next = before.Length + closing.Length;
        byte[] after = [.. before, .. TestPdf.Latin($"{closing}xref\n0 1\n0000000000 65535 f \ntrailer\n<</Size 10 /Root 1 0 R /Prev {xref}>>\nstartxref\n{next}\n%%EOF\n")];

        Assert.Contains(Evil, Encoding.Latin1.GetString(PdfDocument.Open(after).Pages[0].Contents()));
        var report = SignatureOverlapTests.Compare(before, after, 1);

        Assert.Contains(report.NotAllowed, c => c.Kind == SignatureChangeKind.Unreadable);
    }

    [Fact]
    public void An_entry_the_update_lists_where_the_object_is_not_is_a_change()
    {
        var pdf = SignatureSharedRoleTests.Doc(page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /Contents (VOID)>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        long comment = signed.Length + 1;
        byte[] attacked = SignatureForgeryTests.AppendSection(signed, "% nothing here\n", $"6 1\n{comment:D10} 00000 n \n");

        AssertNotAllowed(attacked);
    }

    // ---- numbers a reader may take differently

    [Fact]
    public void A_reference_written_with_a_sign_inside_the_number_is_a_change()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);
        string page = PdfDocument.Open(signed).Get(3)!.ToString()!.Replace("/Contents 4 0 R", "/Contents 4-9 0 R");
        Assert.Contains("4-9", page);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (3, page), (49, StreamBody(Evil)));

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_stamp_whose_area_is_written_with_signs_inside_the_numbers_is_not_empty()
    {
        byte[] before = SignatureOverlapTests.FormPdf().Finish();
        byte[] after = SignatureRoleTests.AppendRaw(before,
            (3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [32 0 R]>>"),
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /V 31 0 R>>"),
            (31, SignatureOverlapTests.StampDict),
            (32, "<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 0-300 0-400] /P 3 0 R>>"));

        Assert.False(SignatureOverlapTests.Compare(before, after, 1, 31).AllAllowed);
    }

    // ---- references nested deeply

    [Fact]
    public void A_dangling_reference_at_the_end_of_a_deep_chain_is_claimed_by_a_new_object()
    {
        string chain = "99 0 R";
        for (int i = 0; i < 40; i++) chain = $"<</S /Named /N /NextPage /Next {chain}>>";
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(catalog: $"/OpenAction {chain}"), CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (99, "<</S /JavaScript /JS (app.alert\\(1\\))>>"));

        AssertNotAllowed(attacked);
    }

    // ---- objects after the signed revision that no table lists

    [Fact]
    public void An_object_header_with_no_gap_before_obj_is_found_like_any_other()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureForgeryTests.AppendSection(signed, $"4 0obj\n{StreamBody(Evil)}\nendobj\n", "");

        AssertUnreadable(attacked);
    }

    [Fact]
    public void An_unlisted_object_for_a_number_the_signed_revision_only_points_at_is_found()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(page: "/Contents [4 0 R 99 0 R]"), CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureForgeryTests.AppendSection(signed, $"99 0 obj\n{StreamBody(Evil)}\nendobj\n", "");

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_listed_copy_that_a_later_update_moves_into_an_object_stream_is_still_a_shadow()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);
        string page = PdfDocument.Open(signed).Get(3)!.ToString()!;
        byte[] second = SignatureRoleTests.AppendRaw(signed,
            (3, "<</Type /Page /Parent 2 0 R /Contents 60 0 R>>"),
            (60, StreamBody(Evil)));

        // The third update lists object 3 again, as the signed text, inside an object stream; the plain copy stays in the file.
        string data = "3 0 " + page;
        var text = new StringBuilder("\n");
        long stream = second.Length + text.Length;
        text.Append($"40 0 obj\n<</Type /ObjStm /N 1 /First 4 /Length {data.Length}>>\nstream\n{data}\nendstream\nendobj\n");
        long table = second.Length + text.Length;
        string entries = Entry(2, 40, 0) + Entry(1, stream, 0) + Entry(1, table, 0);
        text.Append($"41 0 obj\n<</Type /XRef /Size 61 /W [1 4 2] /Index [3 1 40 2] /Root 1 0 R /Prev {PdfDocument.Open(second).StartXref} /Length {entries.Length}>>\nstream\n{entries}\nendstream\nendobj\nstartxref\n{table}\n%%EOF\n");
        byte[] attacked = [.. second, .. TestPdf.Latin(text.ToString())];

        Assert.Equal(page, PdfDocument.Open(attacked).Get(3)!.ToString());
        AssertNotAllowed(attacked);
    }

    private static string Entry(int type, long second, int third) =>
        new([(char)type, (char)(second >> 24 & 255), (char)(second >> 16 & 255), (char)(second >> 8 & 255), (char)(second & 255), (char)(third >> 8 & 255), (char)(third & 255)]);
}
