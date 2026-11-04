using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>Objects that an annotation or field points at and the document uses for something else, and what a lock covers.</summary>
public class SignatureFieldRoleTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static readonly string Digest = new('A', 40);

    private static void AssertNotAllowed(SignatureReport report, int number)
    {
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == number);
    }

    private static TestPdf Stamp(string catalog)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: catalog, page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(7, "<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP 8 0 R>>");
        pdf.Obj(8, "<</N 9 0 R>>");
        pdf.Stream(9, Form, "0 g");
        return pdf;
    }

    [Fact]
    public void An_appearance_dictionary_that_validation_data_also_lists_follows_the_annotation_rule()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(Stamp($"/DSS <</VRI <</{Digest} 8 0 R>>>>"), CertificationLevel.NoChanges);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (8, "<</N 30 0 R>>"), (30, StreamBody(Evil, Form)));

        var report = Check(attacked);
        AssertNotAllowed(report, 8);
        Assert.DoesNotContain(report.Changes.Changes, c => c.Kind == SignatureChangeKind.ValidationData);
    }

    [Fact]
    public void An_appearance_dictionary_that_is_the_information_dictionary_follows_the_annotation_rule()
    {
        byte[] file = Stamp("").Finish("/Root 1 0 R /Info 8 0 R");
        byte[] signed = PdfSigner.Sign(file, SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill });

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (8, "<</N 30 0 R>>"), (30, StreamBody(Evil, Form)));

        var report = Check(attacked);
        AssertNotAllowed(report, 8);
    }

    [Fact]
    public void A_parent_dictionary_that_validation_data_also_lists_cannot_take_a_new_value()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: $"/AcroForm 9 0 R /DSS <</VRI <</{Digest} 6 0 R>>>>", page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(6, "<</FT /Tx /V (100) /DA (0 g /F1 12 Tf)>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /T (Amount) /Parent 6 0 R /Rect [20 20 120 40]>>");
        pdf.Obj(9, "<</Fields [7 0 R]>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.NoChanges);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (6, "<</FT /Tx /V (1000000) /DA (0 g /F1 12 Tf)>>"));

        AssertNotAllowed(Check(attacked), 6);
    }

    [Fact]
    public void A_kids_array_that_validation_data_also_lists_cannot_be_emptied()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 9 0 R /DSS <</Certs 10 0 R>>>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [7 0 R]>>");
        pdf.Stream(4, "", "BT ET");
        pdf.Obj(6, "<</FT /Sig /T (Late) /Kids 10 0 R>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /Rect [10 10 100 40] /P 3 0 R /AP <</N 8 0 R>>>>");
        pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 90 30]", "0 g");
        pdf.Obj(9, "<</Fields [6 0 R]>>");
        pdf.Obj(10, "[7 0 R]");
        byte[] before = pdf.Finish();

        byte[] after = SignatureRoleTests.AppendRaw(before,
            (10, "[]"),
            (6, "<</FT /Sig /T (Late) /Kids 10 0 R /V 30 0 R>>"),
            (30, SignatureOverlapTests.StampDict),
            (8, StreamBody("0 0 1 rg", "/Type /XObject /Subtype /Form /BBox [0 0 90 30]")));

        var report = SignatureOverlapTests.Compare(before, after, 1, 30);
        Assert.Contains(report.NotAllowed, c => c.Kind == SignatureChangeKind.Form && c.Object == 10);
    }

    private static byte[] LockedAmount()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [7 0 R]");
        pdf.Obj(6, "<</FT /Tx /T (client) /Kids [7 0 R]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>");
        return PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill, Lock = new FieldLock(FieldLockAction.Include, ["client"]) });
    }

    [Fact]
    public void A_lock_on_a_field_name_covers_the_fields_below_it()
    {
        byte[] attacked = SignatureChangeTests.Edit(LockedAmount(), d => ((PdfDictionary)d.Get(7)!)["V"] = new PdfString(TestPdf.Latin("1000000"), false));

        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 7);
    }

    [Fact]
    public void A_field_that_a_submit_action_lists_can_still_be_filled()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R 7 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Send) /Rect [20 60 120 80] /A <</S /SubmitForm /F <</FS /URL /F (http://x)>> /Fields [6 0 R]>>>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);

        byte[] filled = SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(6)!)["V"] = new PdfString(TestPdf.Latin("200"), false));

        var report = Check(filled);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 6);
    }
}
