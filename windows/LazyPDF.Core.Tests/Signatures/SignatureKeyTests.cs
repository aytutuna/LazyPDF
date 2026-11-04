using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>Keys no table names are not allowed: comments, read-only fields, the names a lock goes by and the information a countersigner rewrites.</summary>
public class SignatureKeyTests
{
    private static readonly Pki Pki = Pki.Instance;

    private const string Note = "/Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (note)";

    private static byte[] SignedNote()
    {
        var pdf = SignatureSharedRoleTests.Doc(page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(7, $"<<{Note}>>");
        return SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);
    }

    [Theory]
    [InlineData("/A <</S /JavaScript /JS (app.alert(1))>>")]
    [InlineData("/AA <</PO <</S /SetOCGState /State [/OFF 5 0 R]>>>>")]
    [InlineData("/Dest [3 0 R /Fit]")]
    [InlineData("/OC 5 0 R")]
    [InlineData("/StructParent 3")]
    [InlineData("/Rotate 180")]
    public void A_key_that_is_not_part_of_a_comment_is_not_allowed_on_an_existing_one(string key)
    {
        byte[] signed = SignedNote();

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (7, $"<<{Note} {key}>>"));

        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.Comment && c.Object == 7);
    }

    [Theory]
    [InlineData("/Subtype /Screen /Rect [0 0 0 0] /AA <</PO <</S /SetOCGState /State [/OFF 5 0 R]>>>>", false)]
    [InlineData("/Subtype /Link /Rect [0 0 300 400] /A <</S /JavaScript /JS (x)>>", false)]
    [InlineData("/Subtype /FileAttachment /Rect [0 0 10 10] /FS 5 0 R", false)]
    [InlineData("/Subtype /Text /Rect [250 350 270 370] /Contents (one) /T (A) /C [1 0 0] /CA 0.5 /F 4 /Name /Note", true)]
    public void A_new_annotation_is_allowed_for_the_keys_of_a_comment_only(string keys, bool allowed)
    {
        byte[] signed = SignedNote();

        byte[] attacked = SignatureRoleTests.AppendRaw(signed,
            (3, SignatureUseTests.With(signed, 3, "").Replace("/Annots [7 0 R", "/Annots [7 0 R 30 0 R")),
            (30, $"<</Type /Annot {keys}>>"));

        var report = Check(attacked);
        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Comment && c.Object == 30 && c.Allowed == allowed);
    }

    [Fact]
    public void A_comment_whose_text_changes_is_allowed_at_level_three()
    {
        byte[] attacked = SignatureRoleTests.AppendRaw(SignedNote(), (7, "<</Type /Annot /Subtype /Text /Rect [250 350 270 370] /Contents (edited) /C [1 0 0]>>"));

        Assert.Equal(SignatureVerdict.Valid, Check(attacked).Verdict);
    }

    private static byte[] Names(FieldLock fieldLock, bool kids)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: kids ? "/AcroForm <</Fields [6 0 R]>>" : "/AcroForm <</Fields [6 0 R 7 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(6, kids ? "<</FT /Tx /T (client) /V (a) /Kids [7 0 R]>>" : "<</FT /Tx /T (client)>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /Rect [20 20 120 40]>>");
        return PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill, Lock = fieldLock });
    }

    private static SignatureReport Fill(byte[] signed, int field) =>
        Check(SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(field)!)["V"] = new PdfString(TestPdf.Latin("1000000"), false)));

    [Fact]
    public void A_lock_on_a_name_holds_for_a_field_listed_at_the_top_that_a_reader_qualifies_by_its_parent()
    {
        var report = Fill(Names(new FieldLock(FieldLockAction.Include, ["client"]), kids: false), 7);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 7);
    }

    [Fact]
    public void A_lock_on_a_child_holds_for_the_parent_value_it_inherits()
    {
        var report = Fill(Names(new FieldLock(FieldLockAction.Include, ["client.amount"]), kids: true), 6);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 6);
    }

    [Fact]
    public void A_name_in_an_exclude_list_frees_the_fields_below_it()
    {
        var report = Fill(Names(new FieldLock(FieldLockAction.Exclude, ["client"]), kids: true), 7);

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
    }

    [Fact]
    public void A_name_that_is_not_in_an_exclude_list_stays_locked()
    {
        var report = Fill(Names(new FieldLock(FieldLockAction.Exclude, ["other"]), kids: true), 7);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
    }

    [Theory]
    [InlineData("/Ff 1", false)]
    [InlineData("/Ff 4096", true)]
    [InlineData("", true)]
    public void A_read_only_field_is_not_filled(string flags, bool allowed)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, $"<</Type /Annot /Subtype /Widget /FT /Tx {flags} /T (Price) /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);

        var report = Fill(signed, 6);

        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
    }

    [Fact]
    public void A_field_whose_parent_is_read_only_is_not_filled()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(6, "<</FT /Tx /Ff 1 /T (client) /Kids [7 0 R]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Fill(signed, 7).Verdict);
    }

    [Theory]
    [InlineData("/ModDate (D:20261104110307Z) /Producer (Writer 2)", true)]
    [InlineData("/ModDate (D:20261104110307Z) /Producer (Writer 2) /Title (pay 1,000,000)", false)]
    public void A_countersigner_may_rewrite_the_date_and_producer_of_the_information_and_nothing_else(string keys, bool allowed)
    {
        var pdf = SignatureSharedRoleTests.Doc();
        pdf.Obj(10, "<</ModDate (D:20261104110306Z) /Producer (Writer 1)>>");
        byte[] signed = PdfSigner.Sign(pdf.Finish("/Root 1 0 R /Info 10 0 R"), SignatureKit.Request(Pki));

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (10, $"<<{keys}>>"));

        var report = Check(attacked);
        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Metadata && c.Allowed == allowed);
    }
}
