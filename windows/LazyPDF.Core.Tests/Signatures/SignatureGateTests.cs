using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>What the strict reader accepts after the signed bytes: each case is an update that is exact but for one thing.</summary>
public class SignatureGateTests
{
    private static byte[] Signed() => SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.Annotate);

    private static string PageText(byte[] signed) => PdfDocument.Open(signed).Get(3)!.ToString()!;

    private static string Entry(long offset, int generation = 0, char type = 'n') => $"{offset:D10} {generation:D5} {type} \n";

    // An update of page 3 with the text it already had, written the way the writers of this layer write one.
    private static byte[] Update(byte[] signed, string? body = null, string? entries = null, string? trailer = null, string tail = "%%EOF\n", long? startxref = null)
    {
        var document = PdfDocument.Open(signed);
        body ??= $"3 0 obj\n{PageText(signed)}\nendobj\n";
        entries ??= $"3 1\n{Entry(signed.Length)}";
        trailer ??= $"<</Size {document.NextObjectNumber}{Kept(document)} /Prev {document.StartXref}>>";
        long xref = signed.Length + body.Length;
        return [.. signed, .. TestPdf.Latin($"{body}xref\n{entries}trailer\n{trailer}\nstartxref\n{startxref ?? xref}\n{tail}")];
    }

    private static string Trailer(byte[] signed, string size = "", string keys = "", string prev = "")
    {
        var document = PdfDocument.Open(signed);
        return $"<</Size {(size.Length > 0 ? size : document.NextObjectNumber.ToString())}{(keys.Length > 0 ? keys : Kept(document))} /Prev {(prev.Length > 0 ? prev : document.StartXref.ToString())}>>";
    }

    [Fact]
    public void An_update_of_exact_syntax_passes_and_a_page_rewritten_as_it_was_changes_nothing()
    {
        byte[] update = Update(Signed());

        Assert.True(PassesGate(update));
        var report = Check(update);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.True(report.Changes.IsEmpty);
    }

    [Theory]
    [InlineData("\n")]
    [InlineData("\r")]
    [InlineData("\r\n")]
    [InlineData("")]
    public void One_line_end_after_the_last_marker_is_all_there_may_be(string end)
    {
        Assert.True(PassesGate(Update(Signed(), tail: "%%EOF" + end)));
    }

    [Theory]
    [InlineData("%%EOF\n\n")]
    [InlineData("%%EOF \n")]
    [InlineData("%%EOF\n%")]
    [InlineData("%%EOF\n12 0 obj")]
    [InlineData("%EOF\n")]
    [InlineData("%%EOFX\n")]
    [InlineData("")]
    public void Anything_but_one_line_end_after_the_last_marker_fails(string tail)
    {
        AssertUnreadable(Update(Signed(), tail: tail));
    }

    [Theory]
    [InlineData("<</Type /Page % a comment\n/Parent 2 0 R>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /Contents 4-9 0 R>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /Rotate 1e1>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /Rotate +-1>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /Rotate 1.2.3>>")]
    [InlineData("<</Type /Page /Type /Page /Parent 2 0 R>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A (unfinished>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A (bad \\q escape)>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A <6g>>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A#zz 1>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A foo>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A [1 R]>>")]
    [InlineData("<</Type /Page /Parent 2 0 R /A 1 0obj>>")]
    [InlineData("<</Type /Page /Parent 2 0 R endobj /Contents 49 0 R>>")]
    [InlineData("<</Type /Page /Parent 2 0 R>> <</Type /Page>>")]
    [InlineData("<</Type /Page /Parent 2 0 R")]
    public void A_token_or_key_that_is_not_exact_fails_the_update(string page)
    {
        byte[] signed = Signed();

        AssertUnreadable(Update(signed, body: $"3 0 obj\n{page}\nendobj\n"));
    }

    [Theory]
    [InlineData("3 0 obj\n<</Type /Page>>\n")]
    [InlineData("3 0 obj\n<</Type /Page>>\nendobj extra\n")]
    [InlineData("3 0 obj\n<</Type /Page>>\nstream\nabc\nendstream\nendobj\n")]
    [InlineData("3 0 obj\n<</Length 3>>\nstream\nabc\nendstream\nendobj\n")]
    [InlineData("3 0 obj\n<</Length 3>>\nstreamabc\nendstream\nendobj\n")]
    [InlineData("3 0 obj\n<</Length 2>>\nstream\nabc\nendstream\nendobj\n")]
    [InlineData("3 0 obj\n<</Length 9 0 R>>\nstream\nabc\nendstream\nendobj\n")]
    [InlineData("3 0 obj\n<</Length 40>>\nstream\nabc\nendstream\nendobj\n")]
    [InlineData("3 0obj\n<<>>\nendobj\n")]
    [InlineData("3 0 obj <<>> endobj\n% between objects\n")]
    [InlineData("0 0 obj\n<<>>\nendobj\n")]
    public void An_object_that_is_not_exact_fails_the_update(string body)
    {
        byte[] signed = Signed();
        if (body.Contains("Length 3>>\nstream\nabc")) Assert.True(PassesGate(Update(signed, body: body.Replace("<</Length 3>>\nstreamabc", "<</Length 3>>\nstream\nabc"))));

        AssertUnreadable(Update(signed, body: body));
    }

    [Fact]
    public void A_stream_with_its_length_written_directly_passes()
    {
        byte[] signed = Signed();
        string body = "50 0 obj\n<</Length 3>>\nstream\nabc\nendstream\nendobj\n";

        Assert.True(PassesGate(Update(signed, body: body, entries: $"50 1\n{Entry(signed.Length)}", trailer: Trailer(signed, size: "51"))));
    }

    [Fact]
    public void A_table_entry_must_be_twenty_bytes_and_point_at_its_object()
    {
        byte[] signed = Signed();
        long at = signed.Length;

        Assert.True(PassesGate(Update(signed)));
        AssertUnreadable(Update(signed, entries: $"3 1\n{at:D10} 00000 n\n"));
        AssertUnreadable(Update(signed, entries: $"3 1\n{at + 1:D10} 00000 n \n"));
        AssertUnreadable(Update(signed, entries: $"3 1\n{Entry(at, generation: 1)}"));
        AssertUnreadable(Update(signed, entries: $"4 1\n{Entry(at)}"));
        AssertUnreadable(Update(signed, entries: $"3 1\n{Entry(5)}"));
        AssertUnreadable(Update(signed, entries: $"3 1\n{Entry(3_000_000_000)}"));
        AssertUnreadable(Update(signed, entries: $"3 1\n{Entry(at)}3 1\n{Entry(at)}"));
        AssertUnreadable(Update(signed, entries: ""));
    }

    [Fact]
    public void An_object_the_table_does_not_list_fails_the_update()
    {
        byte[] signed = Signed();
        string page = $"3 0 obj\n{PageText(signed)}\nendobj\n";
        string body = page + "60 0 obj\n<<>>\nendobj\n";

        AssertUnreadable(Update(signed, body: body));
        Assert.True(PassesGate(Update(signed, body: body, entries: $"3 1\n{Entry(signed.Length)}60 1\n{Entry(signed.Length + page.Length)}", trailer: Trailer(signed, size: "61"))));
    }

    [Fact]
    public void A_free_entry_passes_and_names_no_object()
    {
        byte[] signed = Signed();

        Assert.True(PassesGate(Update(signed, body: "", entries: $"0 1\n{Entry(0, 65535, 'f')}9 1\n{Entry(0, 1, 'f')}", trailer: Trailer(signed, size: "10"))));
    }

    [Fact]
    public void The_trailer_keeps_the_catalog_and_the_encryption_and_chains_to_the_section_before()
    {
        byte[] signed = Signed();
        var document = PdfDocument.Open(signed);
        string identity = Identity(document);

        Assert.True(PassesGate(Update(signed, trailer: Trailer(signed))));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: $" /Root 1 3 R{identity}")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: $" /Root 1-2 0 R{identity}")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: $" /Root 20 0 R /Root 1 0 R{identity}")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: $" /Root <</Type /Catalog /Pages 2 0 R>>{identity}")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: identity)));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: $"{Kept(document)} /XRefStm 5")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, prev: "12")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, prev: $"{document.StartXref}-5")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: $"{Kept(document)} /Prev 999")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, size: "3")));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, size: "2")));
    }

    [Fact]
    public void An_update_changes_the_second_identity_string_and_keeps_the_first()
    {
        byte[] signed = Signed();
        var id = (PdfArray)PdfDocument.Open(signed).Trailer["ID"]!;
        string first = id.Items[0].ToString()!;
        var document = PdfDocument.Open(signed);
        string Keep(string identity) => $" /Root {document.Trailer["Root"]} /ID [{identity}]";

        Assert.True(PassesGate(Update(signed, trailer: Trailer(signed, keys: Keep($"{first} <00112233445566778899AABBCCDDEEFF>")))));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: Keep($"<00112233445566778899AABBCCDDEEFF> {id.Items[1]}"))));
        AssertUnreadable(Update(signed, trailer: Trailer(signed, keys: Keep(first))));
    }

    [Fact]
    public void An_information_dictionary_may_be_added_but_not_replaced()
    {
        byte[] signed = Signed();
        var document = PdfDocument.Open(signed);
        string kept = Kept(document);
        string title = "60 0 obj\n<</Title (x)>>\nendobj\n";
        string entries = $"60 1\n{Entry(signed.Length)}";

        Assert.True(PassesGate(Update(signed, body: title, entries: entries, trailer: Trailer(signed, size: "61", keys: kept + " /Info 60 0 R"))));
        var withTitle = SignatureSharedRoleTests.Doc();
        withTitle.Obj(6, "<</Title (t)>>");
        byte[] withInfo = PdfSigner.Sign(withTitle.Finish("/Root 1 0 R /Info 6 0 R"), SignatureKit.Request(Pki.Instance));
        AssertUnreadable(Update(withInfo, body: title, entries: entries, trailer: Trailer(withInfo, size: "61", keys: Kept(PdfDocument.Open(withInfo)).Replace("/Info 6 0 R", "/Info 60 0 R"))));
    }

    [Fact]
    public void The_startxref_must_name_the_section_that_was_just_read()
    {
        byte[] signed = Signed();

        Assert.True(PassesGate(Update(signed)));
        AssertUnreadable(Update(signed, startxref: 5));
        AssertUnreadable(Update(signed, startxref: PdfDocument.Open(signed).StartXref));
    }

    [Fact]
    public void A_signed_revision_that_ends_inside_a_comment_leaves_the_update_unjudged()
    {
        byte[] file = OpenSignedTail();

        var update = TestPdf.Latin("stream\nBT ET\nendstream\nendobj\nxref\n0 1\n0000000000 65535 f \ntrailer\n<</Size 10 /Root 1 0 R /Prev 100>>\nstartxref\n100\n%%EOF\n");
        byte[] attacked = [.. file, .. update];

        Assert.Null(UpdateGate.Check(PdfDocument.Open(file), PdfDocument.Open(attacked)));
    }

    // The tail of the signed bytes with a comment that hides the real startxref line; PdfDocument finds the comment's.
    private static byte[] OpenSignedTail()
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
        long xref = pdf.Position;
        string head = "xref\n0 10\n0000000000 65535 f \n"
            + string.Concat(Enumerable.Range(1, 4).Select(n => $"{starts[n]:D10} 00000 n \n"))
            + string.Concat(Enumerable.Repeat("0000000000 00000 f \n", 4));
        const string trailer = "trailer\n<</Size 10 /Root 1 0 R>>\n";
        long open = xref + head.Length + 20 + trailer.Length;
        pdf.Write($"{head}{open:D10} 00000 n \n{trailer}9 0 obj\n<</Length 10>>\n%startxref {xref}\n%%EOF\n");
        return pdf.FinishWithoutXref();
    }

    [Fact]
    public void An_object_stream_is_read_member_by_member_and_every_member_is_listed()
    {
        byte[] signed = Signed();

        Assert.True(PassesGate(WithObjectStream(signed, "55 0 (note)", 1, 5, 55, 0)));
        AssertUnreadable(WithObjectStream(signed, "55 0 56 8 (note) (more)", 2, 10, 55, 0));
        AssertUnreadable(WithObjectStream(signed, "55 0 x (note)", 1, 7, 55, 0));
        AssertUnreadable(WithObjectStream(signed, "55 0 (note", 1, 5, 55, 0));
        AssertUnreadable(WithObjectStream(signed, "55 3    (note)", 1, 5, 55, 0));
        AssertUnreadable(WithObjectStream(signed, "55 0 (note) (gap)", 1, 5, 55, 0));
        AssertUnreadable(WithObjectStream(signed, "55 0 (note)", 1, 5, 55, 1));
    }

    [Fact]
    public void An_object_the_update_replaces_must_have_been_exact_in_the_signed_bytes()
    {
        var pdf = SignatureSharedRoleTests.Doc();
        pdf.Obj(6, "<</A 1\n% odd\n>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);

        Assert.False(PassesGate(Update(signed, body: "6 0 obj\n<<>>\nendobj\n", entries: $"6 1\n{Entry(signed.Length)}")));
        int next = PdfDocument.Open(signed).NextObjectNumber;
        Assert.True(PassesGate(Update(signed, body: $"{next} 0 obj\n<<>>\nendobj\n", entries: $"{next} 1\n{Entry(signed.Length)}", trailer: Trailer(signed, size: (next + 1).ToString()))));
    }
}
