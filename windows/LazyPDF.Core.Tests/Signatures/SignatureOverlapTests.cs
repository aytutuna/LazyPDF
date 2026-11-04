using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Objects with two jobs: a field, an annotation, a list or a stream that something else in the document also uses or draws.</summary>
public class SignatureOverlapTests
{
    private static readonly Pki Pki = Pki.Instance;

    internal const string StampDict = "<</Type /DocTimeStamp /SubFilter /ETSI.RFC3161>>";
    private const string Form = "/Type /XObject /Subtype /Form /BBox [0 0 300 400]";

    private static SignatureReport Check(byte[] file) => SignatureKit.Verify(file)[0];

    private static void AssertNotAllowed(byte[] file)
    {
        var report = Check(file);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.NotEmpty(report.Changes.NotAllowed);
    }

    // A page with an empty /Annots, a form with no fields, and the update's own objects from 30 on.
    internal static TestPdf FormPdf(string catalog = "/AcroForm 9 0 R", string annots = "[]", string fields = "[]")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots {annots}>>");
        pdf.Stream(4, "", "BT ET");
        pdf.Obj(9, $"<</Fields {fields}>>");
        return pdf;
    }

    internal static SignatureChangeReport Compare(byte[] before, byte[] after, int level, params int[] signatures)
    {
        var final = PdfDocument.Open(after);
        return ChangeDetector.Compare(PdfDocument.Open(before), final, level, signatures.Select(n => final.Entries[n].Offset).ToHashSet());
    }

    [Theory]
    [InlineData("widget")]
    [InlineData("field")]
    public void A_time_stamp_field_is_judged_on_its_own_area_and_its_parents_whether_or_not_they_list_it(string kind)
    {
        byte[] before = FormPdf().Finish();
        byte[] after = kind == "widget"
            ? SignatureRoleTests.AppendRaw(before,
                (3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [32 0 R]>>"),
                (9, "<</Fields [30 0 R]>>"),
                (30, "<</FT /Sig /T (Late) /V 31 0 R>>"),
                (31, StampDict),
                (32, "<</Type /Annot /Subtype /Widget /Parent 30 0 R /Rect [0 0 300 400] /P 3 0 R>>"))
            : SignatureRoleTests.AppendRaw(before,
                (9, "<</Fields [30 0 R]>>"),
                (30, "<</FT /Sig /T (Late) /Rect [0 0 300 400] /Parent 34 0 R /V 31 0 R>>"),
                (31, StampDict),
                (34, "<<>>"));

        var report = Compare(before, after, 1, 31);

        Assert.False(report.AllAllowed);
    }

    [Fact]
    public void A_stamp_on_a_field_with_no_area_anywhere_is_still_allowed()
    {
        byte[] before = FormPdf().Finish();
        byte[] after = SignatureRoleTests.AppendRaw(before,
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Rect [0 0 0 0] /V 31 0 R>>"),
            (31, StampDict));

        Assert.True(Compare(before, after, 1, 31).AllAllowed);
    }

    [Fact]
    public void A_new_parent_that_is_no_field_is_not_allowed_with_the_stamp()
    {
        byte[] before = FormPdf().Finish();
        byte[] after = SignatureRoleTests.AppendRaw(before,
            (9, "<</Fields [30 0 R]>>"),
            (30, "<</FT /Sig /T (Late) /Rect [0 0 0 0] /Parent 34 0 R /V 31 0 R>>"),
            (31, StampDict),
            (34, "<<>>"));

        Assert.False(Compare(before, after, 1, 31).AllAllowed);
    }

    [Fact]
    public void A_direct_annotations_appearance_is_a_comment_even_when_validation_data_names_it()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/DSS <</Certs [6 0 R]>>",
            page: "/Contents 4 0 R /Annots [<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP <</N 6 0 R>>>>]");
        pdf.Stream(6, Form, "0 g");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        AssertNotAllowed(SignatureChangeTests.Edit(signed, d => ((PdfStream)d.Get(6)!).Data = TestPdf.Latin("1 g")));
    }

    [Theory]
    [InlineData("action")]
    [InlineData("xfa")]
    public void A_stream_that_an_action_or_the_form_uses_is_not_validation_data_because_a_DSS_lists_it_too(string use)
    {
        var pdf = use == "action"
            ? SignatureSharedRoleTests.Doc(catalog: "/DSS <</Certs [6 0 R]>>", page: "/Contents 4 0 R /Annots [<</Type /Annot /Subtype /Link /Rect [10 10 30 30] /A <</S /JavaScript /JS 6 0 R>>>>]")
            : SignatureSharedRoleTests.Doc(catalog: "/DSS <</Certs [6 0 R]>> /AcroForm 7 0 R");
        if (use == "xfa") pdf.Obj(7, "<</Fields [] /XFA 6 0 R>>");
        pdf.Stream(6, "", "app.alert\\(1\\)");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        AssertNotAllowed(SignatureChangeTests.Edit(signed, d => ((PdfStream)d.Get(6)!).Data = TestPdf.Latin("app.alert(2)")));
    }

    [Fact]
    public void An_appearance_the_metadata_also_is_follows_the_appearance_rule()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/Metadata 6 0 R", page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Stream(6, "/Type /Metadata /Subtype /XML", "<x/>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /AP <</N 6 0 R>>>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        AssertNotAllowed(SignatureChangeTests.Edit(signed, d => ((PdfStream)d.Get(6)!).Data = TestPdf.Latin("<y/>")));
    }

    [Fact]
    public void A_field_that_is_also_an_optional_content_configuration_takes_no_view_state_as_a_fill()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm 8 0 R /OCProperties <</OCGs [7 0 R] /D 6 0 R>>");
        pdf.Obj(6, "<</FT /Tx /T (Layer) /V (a) /BaseState /ON>>");
        pdf.Obj(7, "<</Type /OCG /Name (Layer)>>");
        pdf.Obj(8, "<</Fields [6 0 R]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed,
            (6, "<</FT /Tx /T (Layer) /V (a) /BaseState /ON /AS [<</Event /View /Category [/View] /OCGs [7 0 R]>>]>>"));

        AssertNotAllowed(attacked);
    }

    [Theory]
    [InlineData("annots")]
    [InlineData("fields")]
    public void An_array_shared_with_another_job_is_not_a_list_of_annotations_or_fields(string list)
    {
        var pdf = FormPdf(catalog: "/AcroForm 9 0 R /OCProperties <</OCGs [7 0 R] /D <</OFF 6 0 R>>>>",
            annots: list == "annots" ? "6 0 R" : "[]", fields: list == "fields" ? "6 0 R" : "[]");
        pdf.Obj(6, "[]");
        pdf.Obj(7, "<</Type /OCG /Name (Layer)>>");
        byte[] before = pdf.Finish();
        byte[] after = list == "annots"
            ? SignatureRoleTests.AppendRaw(before, (6, "[7 0 R]"))
            : SignatureRoleTests.AppendRaw(before, (6, "[30 0 R]"), (30, "<</FT /Sig /T (Late) /V 31 0 R>>"), (31, StampDict));

        var report = list == "annots" ? Compare(before, after, 3) : Compare(before, after, 1, 31);

        Assert.False(report.AllAllowed);
    }

    [Fact]
    public void A_stream_a_direct_annotation_draws_is_not_freed_by_an_invisible_signature_field_that_shares_it()
    {
        var pdf = FormPdf(annots: "[<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP <</N 8 0 R>>>>]", fields: "[6 0 R]");
        pdf.Obj(6, "<</FT /Sig /T (Late) /AP <</N 8 0 R>>>>");
        pdf.Stream(8, Form, "0 g");
        byte[] before = pdf.Finish();
        byte[] after = SignatureRoleTests.AppendRaw(before,
            (6, "<</FT /Sig /T (Late) /AP <</N 8 0 R>> /V 31 0 R>>"),
            (8, $"<<{Form} /Length 8>>\nstream\n0 0 1 rg\nendstream"),
            (31, StampDict));

        var report = Compare(before, after, 1, 31);

        Assert.Contains(report.NotAllowed, c => c.Kind == SignatureChangeKind.Comment && c.Object == 8);
    }

    [Fact]
    public void Form_wide_drawing_settings_are_not_allowed_while_a_field_lock_is_in_force()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        byte[] locked = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill, Lock = new FieldLock(FieldLockAction.Include, ["Amount"]) });
        Assert.Equal(SignatureVerdict.Valid, Check(locked).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(locked, d => d.Dict(d.Catalog, "AcroForm")!["NeedAppearances"] = new PdfBoolean(true));

        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.FormFill);
    }
}
