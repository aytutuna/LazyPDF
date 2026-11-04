using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>Streams that are only plumbing, the trailer, and the walk over the whole file: none of them may hide a use of an object.</summary>
public class SignatureCoverageTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static void AssertChanged(byte[] file, SignatureChangeKind? kind = null)
    {
        var report = Check(file);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        if (kind is { } k) Assert.Contains(report.Changes.NotAllowed, c => c.Kind == k);
    }

    private static byte[] SignedAt(TestPdf pdf, CertificationLevel level) =>
        PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = level });

    private static string Be(long value) => new([.. Enumerable.Range(0, 8).Select(i => (char)(value >> 8 * (7 - i) & 255))]);

    // A cross-reference stream whose four free rows spell a page's content, as number 99 that the signed page names and nothing defines.
    private static byte[] FreeRowsSpellContent(byte[] signed)
    {
        var document = PdfDocument.Open(signed);
        string[] words = ["BT /F1 18 Tf", "40 300 Td", "(pay 1,000,000)", "Tj ET %"];
        string rows = string.Concat(words.Select(w => "\0" + w.PadRight(16)));
        long at = signed.Length + 1;
        rows += "\u0001" + Be(at) + Be(0);
        string body = $"<</Type /XRef /Size 104 /W [1 8 8] /Index [100 4 99 1] {Kept(document)} /Prev {document.StartXref} /Length {rows.Length}>>\nstream\n{rows}\nendstream";
        string text = $"\n99 0 obj\n{body}\nendobj\nstartxref\n{at}\n%%EOF\n";
        return [.. signed, .. TestPdf.Latin(text)];
    }

    [Theory]
    [InlineData(CertificationLevel.NoChanges)]
    [InlineData(CertificationLevel.Annotate)]
    public void A_cross_reference_stream_on_a_number_the_signed_page_names_is_judged_as_the_content_it_becomes(CertificationLevel level)
    {
        byte[] signed = SignedAt(SignatureSharedRoleTests.Doc(page: "/Contents [4 0 R 99 0 R]"), level);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = FreeRowsSpellContent(signed);

        Assert.True(ShowsEvil(attacked));
        AssertChanged(attacked, SignatureChangeKind.PageContent);
    }

    [Fact]
    public void An_object_stream_and_cross_reference_stream_nothing_names_are_not_changes_of_their_own()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);
        string member = "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (200) /Rect [20 20 120 40]>>";

        byte[] filled = WithObjectStream(signed, "6 0 " + member, 1, 4, 6, 0);

        var report = Check(filled);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 6);
        Assert.DoesNotContain(report.Changes.Changes, c => c.Object is 40 or 41);
    }

    [Fact]
    public void An_object_stream_a_page_names_is_judged_by_that_use()
    {
        byte[] signed = SignedAt(SignatureSharedRoleTests.Doc(page: "/Contents [4 0 R 40 0 R]"), CertificationLevel.Annotate);

        byte[] attacked = WithObjectStream(signed, "55 0 (note)", 1, 5, 55, 0);

        AssertChanged(attacked);
    }

    [Theory]
    [InlineData("/Info <</Title (pay 1,000,000) /Author (Mallory)>>", CertificationLevel.None)]
    [InlineData("/Info <</Title (pay 1,000,000) /Author (Mallory)>>", CertificationLevel.FormFill)]
    [InlineData("/Info 5 0 R", CertificationLevel.None)]
    [InlineData("/Info 5 0 R", CertificationLevel.FormFill)]
    public void Information_added_to_the_trailer_without_an_object_of_its_own_is_not_accepted(string info, CertificationLevel level)
    {
        byte[] signed = SignedAt(SignatureSharedRoleTests.Doc(), level);

        byte[] attacked = Append(signed, " " + info, null);

        Assert.False(PassesGate(attacked));
        AssertChanged(attacked, SignatureChangeKind.Unreadable);
    }

    [Theory]
    [InlineData(CertificationLevel.None, "/Title (Quarterly)", false)]
    [InlineData(CertificationLevel.NoChanges, "/Title (Quarterly)", false)]
    [InlineData(CertificationLevel.FormFill, "/Title (Quarterly)", true)]
    [InlineData(CertificationLevel.None, "/Producer (Writer) /ModDate (D:20261104110306Z)", true)]
    [InlineData(CertificationLevel.NoChanges, "/Producer (Writer) /ModDate (D:20261104110306Z)", true)]
    public void Information_added_as_an_object_is_judged_as_metadata(CertificationLevel level, string keys, bool allowed)
    {
        byte[] signed = SignedAt(SignatureSharedRoleTests.Doc(), level);

        byte[] attacked = Append(signed, " /Info 30 0 R", null, (30, $"<<{keys}>>"));

        var report = Check(attacked);
        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Metadata && c.Object == 30 && c.Allowed == allowed);
    }

    [Fact]
    public void Information_whose_dates_move_again_in_a_later_update_is_still_judged()
    {
        byte[] signed = SignedAt(SignatureSharedRoleTests.Doc(), CertificationLevel.None);
        byte[] first = Append(signed, " /Info 30 0 R", null, (30, "<</ModDate (D:20261104110306Z)>>"));

        byte[] second = Append(first, "", null, (30, "<</Title (pay 1,000,000)>>"));

        Assert.Equal(SignatureVerdict.Valid, Check(first).Verdict);
        AssertChanged(second, SignatureChangeKind.Metadata);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(1)]
    [InlineData(8_000_000)]
    public void A_size_that_is_not_the_first_number_in_no_use_is_not_accepted(int by)
    {
        byte[] signed = SignedAt(SignatureSharedRoleTests.Doc(), CertificationLevel.Annotate);

        byte[] attacked = Append(signed, "", PdfDocument.Open(signed).NextObjectNumber + by);

        AssertChanged(attacked, SignatureChangeKind.Unreadable);
        Assert.Equal(SignatureVerdict.Valid, Check(Append(signed, "", null)).Verdict);
    }

    [Fact]
    public void A_trailer_key_a_writer_left_in_the_signed_revision_does_not_fail_the_updates_after_it()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        byte[] source = pdf.Finish("/Root 1 0 R /DocChecksum /ABCDEF");
        byte[] signed = PdfSigner.Sign(source, SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill });
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Amount", "200"));
        byte[] second = PdfSigner.Sign(filled, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, FieldName = "Second" });

        Assert.All(SignatureKit.Verify(filled), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
        Assert.All(SignatureKit.Verify(second), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
    }

    [Theory]
    [InlineData("length")]
    [InlineData("escape")]
    public void A_signed_object_a_conforming_writer_made_can_be_replaced(string oddity)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        string tip = oddity == "escape" ? "/TU (Am\\qount)" : "";
        pdf.Obj(6, $"<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) {tip} /V (100) /Rect [20 20 120 40] /AP <</N 8 0 R>>>>");
        string length = oddity == "length" ? " /Length 9 0 R" : "";
        pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 100 20]" + length, "0 g", oddity == "length" ? -1 : null);
        if (oddity == "length") pdf.Obj(9, "3");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);
        string now = oddity == "escape" ? "/TU (Amqount)" : "";

        byte[] filled = SignatureRoleTests.AppendRaw(signed,
            (6, $"<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) {now} /V (200) /Rect [20 20 120 40] /AP <</N 8 0 R>>>>"),
            (8, StreamBody("0 g 1 g", "/Type /XObject /Subtype /Form /BBox [0 0 100 20]")));

        var report = Check(filled);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 6);
    }

    // 2700 pages that share a long chain of resources: every page walks the chain again under its own page number.
    private static TestPdf SharedChain(int pages, int chain)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /DSS <</Certs [4 0 R]>>>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [{string.Join(' ', Enumerable.Range(0, pages).Select(i => $"{100 + i} 0 R"))}] /Count {pages} /MediaBox [0 0 300 400]>>");
        pdf.Stream(4, "", "BT ET");
        for (int i = 0; i < pages; i++) pdf.Obj(100 + i, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Resources 3000 0 R>>");
        for (int i = 0; i < chain; i++) pdf.Obj(3000 + i, i + 1 < chain ? $"<</Next {3001 + i} 0 R>>" : "<<>>");
        return pdf;
    }

    [Fact]
    public void A_walk_that_a_cap_ended_early_is_not_taken_for_complete()
    {
        byte[] signed = SignedAt(SharedChain(2700, 2000), CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (4, StreamBody(Evil)));

        Assert.False(new Jobs(PdfDocument.Open(signed)).Complete);
        Assert.True(ShowsEvil(attacked));
        AssertChanged(attacked, SignatureChangeKind.Unreadable);
    }

    [Fact]
    public void A_walk_over_a_file_of_ordinary_size_is_complete()
    {
        byte[] signed = SignedAt(SharedChain(40, 50), CertificationLevel.NoChanges);

        Assert.True(new Jobs(PdfDocument.Open(signed)).Complete);
    }

    [Fact]
    public void Fields_nested_deeper_than_the_walk_goes_make_the_file_unreadable_not_unnamed()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [10 0 R]>>");
        for (int i = 0; i < 40; i++) pdf.Obj(10 + i, i < 39 ? $"<</FT /Tx /T (n{i}) /Kids [{11 + i} 0 R]>>" : "<</FT /Tx /T (leaf) /V (1)>>");
        byte[] signed = SignedAt(pdf, CertificationLevel.FormFill);

        Assert.False(new Jobs(PdfDocument.Open(signed)).Complete);
        AssertChanged(SignatureRoleTests.AppendRaw(signed, (49, "<</FT /Tx /T (leaf) /V (2)>>")), SignatureChangeKind.Unreadable);
    }
}
