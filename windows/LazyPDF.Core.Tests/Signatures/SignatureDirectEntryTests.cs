using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>Annotations written inside an /Annots array, the page a bead names, the structure tree, a signature field typed by its parent and the bytes after the last %%EOF.</summary>
public class SignatureDirectEntryTests
{
    private const string Link = "<</Type /Annot /Subtype /Link /Rect [10 10 50 50] /A <</S /URI /URI (http://a)>>>>";

    private static byte[] SignedLink(bool indirectList = false)
    {
        var pdf = indirectList
            ? SignatureSharedRoleTests.Doc(page: "/Contents 4 0 R /Annots 7 0 R")
            : SignatureSharedRoleTests.Doc(page: $"/Contents 4 0 R /Annots [{Link}]");
        if (indirectList) pdf.Obj(7, $"[{Link}]");
        return SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);
    }

    private static byte[] Rewritten(byte[] signed, bool indirectList, Func<string, string> change)
    {
        int holder = indirectList ? 7 : 3;
        string text = PdfDocument.Open(signed).Get(holder)!.ToString()!;
        return SignatureRoleTests.AppendRaw(signed, (holder, change(text)));
    }

    private static string Prepend(string text, string marker, string entry)
    {
        int at = text.IndexOf(marker, StringComparison.Ordinal) + marker.Length;
        return text[..at] + entry + " " + text[at..];
    }

    [Theory]
    [InlineData(false, "retarget", false)]
    [InlineData(true, "retarget", false)]
    [InlineData(false, "script", false)]
    [InlineData(true, "script", false)]
    [InlineData(false, "layer", false)]
    [InlineData(false, "note", true)]
    [InlineData(true, "note", true)]
    public void A_direct_annotation_is_judged_by_the_keys_of_a_comment(bool indirectList, string edit, bool allowed)
    {
        byte[] signed = SignedLink(indirectList);
        string first = indirectList ? "[" : "/Annots [";

        string entry = edit switch
        {
            "script" => "<</Type /Annot /Subtype /Screen /Rect [0 0 0 0] /AA <</PO <</S /JavaScript /JS (x)>>>>>>",
            "layer" => "<</Type /Annot /Subtype /Link /Rect [0 0 300 400] /A <</S /JavaScript /JS (x)>> /OC 5 0 R>>",
            _ => "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /T (A)>>",
        };
        byte[] attacked = Rewritten(signed, indirectList, text => edit == "retarget" ? text.Replace("http://a", "http://evil") : Prepend(text, first, entry));

        var report = Check(attacked);
        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
        if (!allowed) Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.Comment);
    }

    [Fact]
    public void A_direct_annotation_that_is_dropped_is_a_removed_comment()
    {
        byte[] signed = SignedLink();

        byte[] attacked = Rewritten(signed, false, text => text.Replace(Link, ""));

        Assert.NotEqual(signed.Length, attacked.Length);
        Assert.Equal(SignatureVerdict.Valid, Check(attacked).Verdict);
    }

    private static byte[] SignedBead()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/Threads [10 0 R]", page: "/Contents 4 0 R /B [9 0 R]");
        pdf.Obj(9, "<</Type /Bead /T 10 0 R /N 9 0 R /V 9 0 R /P 3 0 R /R [0 0 100 100]>>");
        pdf.Obj(10, "<</Type /Thread /F 9 0 R>>");
        return SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);
    }

    [Fact]
    public void A_bead_that_names_a_page_does_not_give_it_a_second_use()
    {
        byte[] attacked = SignatureChangeTests.Edit(SignedBead(), d => new PdfAnnotationWriter(d).AddNote(d.Pages[0], new PdfRect(250, 350, 270, 370), new AnnotationInfo("A", "Looks fine")));

        Assert.Equal(SignatureVerdict.Valid, Check(attacked).Verdict);
    }

    private static byte[] SignedTagged(string kid)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/StructTreeRoot 11 0 R", page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /T (A)>>");
        pdf.Obj(11, "<</Type /StructTreeRoot /K 12 0 R>>");
        pdf.Obj(12, $"<</Type /StructElem /S /P /P 11 0 R /Pg 3 0 R /K {kid}>>");
        pdf.Obj(13, "<</Type /OBJR /Pg 3 0 R /Obj 7 0 R>>");
        return SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);
    }

    [Theory]
    [InlineData("13 0 R", SignatureVerdict.Valid)]
    [InlineData("7 0 R", SignatureVerdict.ChangedAfterSigning)]
    public void The_structure_tree_names_an_annotation_through_an_object_reference_only(string kid, SignatureVerdict verdict)
    {
        byte[] attacked = SignatureRoleTests.AppendRaw(SignedTagged(kid), (7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (edited) /T (A)>>"));

        Assert.Equal(verdict, Check(attacked).Verdict);
    }

    [Fact]
    public void A_signature_field_typed_by_a_parent_that_does_not_list_it_is_still_a_signature()
    {
        var pdf = SignatureOverlapTests.FormPdf(annots: "[6 0 R]", fields: "[6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /T (Sign) /Parent 7 0 R /Rect [10 10 100 40] /P 3 0 R /V 10 0 R /AP <</N 8 0 R>>>>");
        pdf.Obj(7, "<</FT /Sig>>");
        pdf.Stream(8, Form, "0 g");
        pdf.Obj(10, "<</Type /Sig>>");
        byte[] before = pdf.Finish();

        byte[] after = SignatureRoleTests.AppendRaw(before, (8, StreamBody(Evil, Form)));

        Assert.False(SignatureOverlapTests.Compare(before, after, 2).AllAllowed);
    }

    [Theory]
    [InlineData("/Rect [0 0 0 0]")]
    [InlineData("/Rect [0 0 0 0] /F 2")]
    [InlineData("/Rect [0 0 300 400] /F 2")]
    public void A_time_stamp_does_not_move_a_signature_field_that_was_on_the_page(string placed)
    {
        var pdf = SignatureOverlapTests.FormPdf(annots: "[6 0 R]", fields: "[6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Sig /T (Late) /Rect [0 0 300 400] /P 3 0 R /AP <</N 8 0 R>>>>");
        pdf.Stream(8, Form, "BT /F1 18 Tf 40 300 Td (NOT APPROVED) Tj ET");
        byte[] before = pdf.Finish();

        byte[] after = SignatureRoleTests.AppendRaw(before,
            (6, $"<</Type /Annot /Subtype /Widget /FT /Sig /T (Late) {placed} /P 3 0 R /AP <</N 8 0 R>> /V 31 0 R>>"),
            (31, SignatureOverlapTests.StampDict));

        Assert.False(SignatureOverlapTests.Compare(before, after, 1, 31).AllAllowed);
    }

    [Theory]
    [InlineData("\n", SignatureVerdict.Valid)]
    [InlineData("\r\n", SignatureVerdict.Valid)]
    [InlineData("\r", SignatureVerdict.Valid)]
    [InlineData("\n\n", SignatureVerdict.ChangedAfterSigning)]
    [InlineData(" ", SignatureVerdict.ChangedAfterSigning)]
    public void One_end_of_line_may_follow_the_signed_bytes_and_nothing_else(string tail, SignatureVerdict verdict)
    {
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.FormFill);

        var report = Check([.. signed, .. TestPdf.Latin(tail)]);

        Assert.Equal(verdict, report.Verdict);
    }

    [Fact]
    public void A_long_run_of_white_space_after_the_signed_bytes_is_a_change()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.FormFill);

        var report = Check([.. signed, .. TestPdf.Latin(new string(' ', 5000))]);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.False(report.CoversWholeFile);
    }
}
