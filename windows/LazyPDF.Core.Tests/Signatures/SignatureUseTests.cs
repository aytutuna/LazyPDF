using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>What a name, a back link or a destination stands for in the walk: a use, or only a way to name.</summary>
public class SignatureUseTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static PdfString Text(string value) => new(TestPdf.Latin(value), false);

    private static void AssertChanged(byte[] file, int number)
    {
        var report = Check(file);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == number);
    }

    private static string Kinds(byte[] file, int number) =>
        string.Join(' ', new Jobs(PdfDocument.Open(file)).Of(number).Select(j => j.Kind).Distinct().Order());

    private static byte[] Second(byte[] file) =>
        PdfSigner.Sign(file, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, FieldName = "Second" });

    [Fact]
    public void A_parent_that_does_not_list_its_child_back_is_a_use_of_it()
    {
        var pdf = SignatureSharedRoleTests.Doc(page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 7 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R /Annots [7 0 R]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note)>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);

        Assert.Equal("Plain Comment", Kinds(signed, 7));
        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /Rotate 180>>"));
        AssertChanged(attacked, 7);
    }

    [Fact]
    public void A_parent_that_lists_its_child_and_a_popup_that_names_its_annotation_are_not_uses()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R 8 0 R 9 0 R]");
        pdf.Obj(6, "<</FT /Tx /T (client) /Kids [9 0 R]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note) /Popup 8 0 R>>");
        pdf.Obj(8, "<</Type /Annot /Subtype /Popup /Rect [250 300 300 340] /Parent 7 0 R>>");
        pdf.Obj(9, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);

        Assert.Equal("Comment", Kinds(signed, 7));
        Assert.Equal("Comment", Kinds(signed, 8));
        Assert.Equal("Field", Kinds(signed, 6));
        byte[] edited = SignatureRoleTests.AppendRaw(signed, (7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (edited) /Popup 8 0 R>>"));
        Assert.Equal(SignatureVerdict.Valid, Check(edited).Verdict);
    }

    [Fact]
    public void A_stamp_field_a_signed_page_names_as_its_parent_is_not_allowed_after_a_certification()
    {
        byte[] before = SignatureOverlapTests.FormPdf(annots: "[]").Finish();
        byte[] named = SignatureRoleTests.AppendRaw(before, (3, "<</Type /Page /Parent 30 0 R /Contents 4 0 R /Annots []>>"));
        byte[] after = SignatureRoleTests.AppendRaw(named,
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Rotate 180 /Resources <<>> /V 31 0 R>>"),
            (31, SignatureOverlapTests.StampDict));

        var report = SignatureOverlapTests.Compare(named, after, 1, 31);

        Assert.False(report.AllAllowed);
        Assert.Contains(report.NotAllowed, c => c.Object == 30);
    }

    [Theory]
    [InlineData("a text annotation", "/Subtype /Text /S /Hide /T 8 0 R")]
    [InlineData("the form", "")]
    public void A_dictionary_that_calls_itself_a_hide_or_reset_action_names_nothing_unless_it_is_one(string where, string keys)
    {
        var pdf = SignatureSharedRoleTests.Doc(
            catalog: where == "the form" ? "/AcroForm <</Fields 8 0 R /S /ResetForm>> /DSS <</Certs [8 0 R]>>" : "/DSS <</Certs [8 0 R]>>",
            page: where == "the form" ? "/Contents 4 0 R" : "/Contents 4 0 R /Annots [7 0 R]");
        if (where != "the form") pdf.Obj(7, $"<</Type /Annot {keys} /Rect [250 350 270 370]>>");
        pdf.Obj(8, where == "the form" ? "[6 0 R]" : "(Alice, Legal)");
        if (where == "the form") pdf.Obj(6, "<</FT /Tx /T (Amount) /V (100)>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (8, where == "the form" ? "[]" : "(Mallory)"));

        AssertChanged(attacked, 8);
    }

    [Theory]
    [InlineData(CertificationLevel.None)]
    [InlineData(CertificationLevel.FormFill)]
    public void A_page_a_destination_names_can_take_the_widget_of_a_signature(CertificationLevel level)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/OpenAction [3 0 R /Fit] /Outlines 20 0 R");
        pdf.Obj(20, "<</Type /Outlines /First 21 0 R /Last 21 0 R /Count 1>>");
        pdf.Obj(21, "<</Title (One) /Parent 20 0 R /Dest [3 0 R /XYZ 0 0 0]>>");
        byte[] first = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = level });

        byte[] both = Second(first);

        Assert.All(SignatureKit.Verify(both), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
    }

    [Fact]
    public void A_page_a_destination_names_can_take_a_note()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/OpenAction [3 0 R /Fit]");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);

        byte[] noted = SignatureChangeTests.Edit(signed, d => new PdfAnnotationWriter(d).AddNote(d.Pages[0], new PdfRect(250, 350, 270, 370), new AnnotationInfo("A", "one")));

        var report = Check(noted);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Comment);
    }

    [Fact]
    public void A_page_something_else_uses_is_still_a_page_with_a_second_job()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/OpenAction <</S /Named /N 3 0 R>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);

        Assert.Contains("Plain", Kinds(signed, 3));
    }

    [Fact]
    public void A_signature_in_a_field_that_has_no_widget_gives_it_one_without_the_first_reading_as_changed()
    {
        foreach (var level in new[] { CertificationLevel.None, CertificationLevel.FormFill })
        {
            var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R 7 0 R]>>");
            pdf.Obj(6, "<</FT /Sig /T (A)>>");
            pdf.Obj(7, "<</FT /Sig /T (B)>>");
            byte[] first = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { FieldName = "A", Certify = level });

            byte[] both = PdfSigner.Sign(first, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, FieldName = "B" });

            Assert.All(SignatureKit.Verify(both), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
        }
    }

    [Fact]
    public void A_font_that_the_forms_defaults_gain_is_the_one_the_new_appearance_draws_with()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /DA (/Helv 12 Tf 0 g) /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);

        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Amount", "200"));

        Assert.Contains("DR", TestPdf.Text(filled)[signed.Length..]);
        var report = Check(filled);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 6);
    }

    [Fact]
    public void A_font_of_the_forms_defaults_cannot_be_changed_when_something_signed_draws_with_it()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R] /DR <</Font <</Helv 5 0 R>>>>>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);

        Assert.Equal("Content Defaults", Kinds(signed, 5));
        AssertChanged(SignatureRoleTests.AppendRaw(signed, (5, "<</Type /Font /Subtype /Type1 /BaseFont /Courier>>")), 5);
    }

    // An object as the signed file has it with more keys at its end.
    internal static string With(byte[] file, int number, string keys)
    {
        string text = PdfDocument.Open(file).Get(number)!.ToString()!;
        return text[..text.LastIndexOf(">>", StringComparison.Ordinal)] + keys + ">>";
    }

    [Fact]
    public void A_time_stamp_of_a_validation_entry_is_validation_data()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(SignatureSharedRoleTests.Doc(), CertificationLevel.None);
        string key = new('a', 40);
        byte[] after = SignatureRoleTests.AppendRaw(signed,
            (1, With(signed, 1, " /DSS 30 0 R")),
            (30, "<</VRI 31 0 R>>"),
            (31, $"<</{key} 33 0 R>>"),
            (33, "<</TS 32 0 R>>"),
            (32, StreamBody("token")));

        var report = Check(after);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.All(report.Changes.Changes, c => Assert.Equal(SignatureChangeKind.ValidationData, c.Kind));
    }
}
