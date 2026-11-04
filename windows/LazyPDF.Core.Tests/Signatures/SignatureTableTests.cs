using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>What the update's tables, trailers and object streams say that the reader's own view of them leaves out.</summary>
public class SignatureTableTests
{
    private static byte[] Signed() => SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.NoChanges);

    // The trailer the test writes, with the identity of the file it follows added before its end.
    private static string Closed(byte[] signed, Func<long, string> trailer)
    {
        var document = PdfDocument.Open(signed);
        string text = trailer(document.StartXref);
        return text[..^2] + Identity(document) + ">>";
    }

    // An update with a second catalog and a trailer written as given.
    private static byte[] WithTrailer(byte[] signed, Func<long, string> trailer)
    {
        var text = new StringBuilder("\n");
        long catalog = signed.Length + text.Length;
        text.Append("12 0 obj\n<</Type /Catalog /Pages 13 0 R>>\nendobj\n");
        long pages = signed.Length + text.Length;
        text.Append("13 0 obj\n<</Type /Pages /Kids [] /Count 0>>\nendobj\n");
        long table = signed.Length + text.Length;
        text.Append($"xref\n12 2\n{catalog:D10} 00000 n \n{pages:D10} 00000 n \ntrailer\n{Closed(signed, trailer)}\nstartxref\n{table}\n%%EOF\n");
        return [.. signed, .. TestPdf.Latin(text.ToString())];
    }

    [Fact]
    public void A_trailer_root_with_a_sign_inside_the_number_is_not_allowed()
    {
        byte[] attacked = WithTrailer(Signed(), prev => $"<</Size 40 /Root 1-2 0 R /Prev {prev}>>");

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_trailer_key_after_an_endobj_is_not_allowed()
    {
        byte[] attacked = WithTrailer(Signed(), prev => $"<</Size 40 /Prev {prev} /Root 1 0 R endobj /Root 12 0 R>>");

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_prev_with_a_sign_inside_the_number_is_not_allowed()
    {
        byte[] attacked = WithTrailer(Signed(), prev => $"<</Size 40 /Root 1 0 R /Prev {prev}-5>>");

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_repeated_prev_is_not_allowed()
    {
        byte[] attacked = WithTrailer(Signed(), prev => $"<</Size 40 /Root 1 0 R /Prev 999 /Prev {prev}>>");

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_number_listed_twice_in_one_table_is_not_allowed()
    {
        byte[] signed = Signed();
        var document = PdfDocument.Open(signed);
        long good = document.Entries[3].Offset;
        string page = document.Get(3)!.ToString()!.Replace("/Contents 4 0 R", "/Contents 49 0 R");
        string inner = $"\n3 0 obj\n{page}\nendobj\n";
        var text = new StringBuilder("\n");
        long holder = signed.Length + text.Length;
        string head = $"50 0 obj\n<</Length {inner.Length}>>\nstream\n";
        text.Append(head).Append(inner).Append("\nendstream\nendobj\n");
        long hidden = holder + head.Length + 1;
        long stream = signed.Length + text.Length;
        text.Append($"49 0 obj\n{StreamBody(Evil)}\nendobj\n");
        long table = signed.Length + text.Length;
        text.Append($"xref\n3 1\n{good:D10} 00000 n \n3 1\n{hidden:D10} 00000 n \n49 2\n{stream:D10} 00000 n \n{holder:D10} 00000 n \n");
        text.Append($"trailer\n<</Size 51{Kept(document)} /Prev {document.StartXref}>>\nstartxref\n{table}\n%%EOF\n");

        AssertUnreadable([.. signed, .. TestPdf.Latin(text.ToString())]);
    }

    private static TestPdf StampedDoc()
    {
        var pdf = SignatureSharedRoleTests.Doc(page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /Contents (VOID)>>");
        return pdf;
    }

    [Theory]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, false)]
    public void An_entry_that_leads_to_another_object_is_not_allowed(bool intoSigned, bool closed)
    {
        byte[] signed = SignatureSharedRoleTests.Sign(StampedDoc(), CertificationLevel.NoChanges);
        long offset = intoSigned ? 5 : signed.Length + 1;
        byte[] attacked = SignatureForgeryTests.AppendSection(signed, intoSigned ? "" : "% nothing here\n", $"6 1\n{offset:D10} 00000 n \n");
        if (!closed)
        {
            string text = TestPdf.Text(attacked);
            attacked = TestPdf.Latin(text[..text.LastIndexOf("%%EOF", StringComparison.Ordinal)]);
        }

        AssertUnreadable(attacked);
    }

    [Fact]
    public void An_entry_with_an_offset_past_the_int_range_is_a_change_and_not_a_crash()
    {
        byte[] attacked = SignatureForgeryTests.AppendSection(Signed(), "", "77 1\n3000000000 00000 n \n");

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_member_of_an_object_stream_is_read_from_its_own_start()
    {
        byte[] signed = Signed();
        string page = PdfDocument.Open(signed).Get(3)!.ToString()!.Replace("/Contents 4 0 R", "/Contents 4-9 0 R");

        foreach (string gap in new[] { "3 0 endobj ", "3 0 ( " })
        {
            AssertUnreadable(WithObjectStream(signed, gap + page, 1, gap.Length, 3, 0, (49, StreamBody(Evil))));
        }
    }

    [Fact]
    public void An_object_stream_that_lists_a_number_twice_is_not_allowed()
    {
        byte[] signed = Signed();
        string good = PdfDocument.Open(signed).Get(3)!.ToString()!;
        string evil = good.Replace("/Contents 4 0 R", "/Contents 49 0 R");
        string head = $"3 0 3 {good.Length + 1} ";

        byte[] attacked = WithObjectStream(signed, head + good + " " + evil, 2, head.Length, 3, 1, (49, StreamBody(Evil)));

        AssertUnreadable(attacked);
    }

    [Fact]
    public void An_entry_that_names_the_wrong_member_of_an_object_stream_is_not_allowed()
    {
        byte[] signed = Signed();
        string good = PdfDocument.Open(signed).Get(3)!.ToString()!;
        string evil = good.Replace("/Contents 4 0 R", "/Contents 49 0 R");
        string head = $"7 0 3 {evil.Length + 1} ";

        byte[] attacked = WithObjectStream(signed, head + evil + " " + good, 2, head.Length, 3, 0, (49, StreamBody(Evil)));

        AssertUnreadable(attacked);
    }

    [Fact]
    public void A_well_formed_object_stream_with_a_new_member_is_not_reported()
    {
        byte[] signed = Signed();
        string head = "55 0 ";

        byte[] update = WithObjectStream(signed, head + "(note)", 1, head.Length, 55, 0);

        // The bytes are exact; a member that nothing refers to is still not something the signer allowed.
        Assert.True(PassesGate(update));
        var report = Check(update);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.Other && c.Object == 55);
    }

    [Fact]
    public void An_endobj_inside_a_dictionary_hides_what_follows_it()
    {
        byte[] signed = Signed();
        string page = PdfDocument.Open(signed).Get(3)!.ToString()!;
        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (3, page[..^2] + " endobj /Contents 49 0 R>>"), (49, StreamBody(Evil)));

        AssertUnreadable(attacked);
    }

    [Fact]
    public void An_entry_moved_back_to_an_older_copy_with_an_odd_number_is_not_allowed()
    {
        var pdf = SignatureSharedRoleTests.Doc();
        long old = pdf.Position;
        pdf.Write("3 0 obj\n<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4-9 0 R>>\nendobj\n");
        pdf.Obj(6, "<<>>");
        byte[] before = pdf.Finish();
        var document = PdfDocument.Open(before);
        long evil = before.Length + 1;
        var text = new StringBuilder($"\n49 0 obj\n{StreamBody(Evil)}\nendobj\n");
        long table = before.Length + text.Length;
        text.Append($"xref\n3 1\n{old:D10} 00000 n \n49 1\n{evil:D10} 00000 n \ntrailer\n<</Size 50{Kept(document)} /Prev {document.StartXref}>>\nstartxref\n{table}\n%%EOF\n");
        byte[] after = [.. before, .. TestPdf.Latin(text.ToString())];

        Assert.Contains(SignatureOverlapTests.Compare(before, after, 1).NotAllowed, c => c.Kind == SignatureChangeKind.Unreadable);
    }
}
