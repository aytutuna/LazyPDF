using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Objects that hold two jobs, entries the signed revision could not read and list entries that look the same but are not.</summary>
public class SignatureSharedRoleTests
{
    private static readonly Pki Pki = Pki.Instance;

    private const string Evil = "BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET";

    private static SignatureReport Check(byte[] file) => SignatureKit.Verify(file)[0];

    internal static TestPdf Doc(string catalog = "", string page = "/Contents 4 0 R")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> {page}>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        return pdf;
    }

    internal static byte[] Sign(TestPdf pdf, CertificationLevel level) =>
        PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = level });

    private static void AssertNotAllowed(SignatureReport report, SignatureChangeKind? kind = null)
    {
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        if (kind is { } k) Assert.Contains(report.Changes.NotAllowed, c => c.Kind == k);
    }

    [Fact]
    public void An_object_the_signed_revision_could_not_read_shows_the_updates_bytes_as_new()
    {
        var pdf = Doc(page: "/Contents [4 0 R 9 0 R]");
        pdf.Obj(9, $"<</Length {Evil.Length} /X (");
        byte[] signed = Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureForgeryTests.AppendSection(signed, $")>>\nstream\n{Evil}\nendstream\nendobj\n", "");

        Assert.Contains("pay 1,000,000", Encoding.Latin1.GetString(PdfDocument.Open(attacked).Pages[0].Contents()));
        AssertNotAllowed(Check(attacked), SignatureChangeKind.Unreadable);
    }

    [Fact]
    public void A_shadow_the_repair_of_a_wrong_table_entry_finds_is_still_a_change()
    {
        var pdf = new TestPdf();
        pdf.Stream(1, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(2, "<</Type /Catalog /Pages 3 0 R>>");
        pdf.Obj(3, "<</Type /Pages /Kids [4 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(4, "<</Type /Page /Parent 3 0 R /Contents 1 0 R>>");
        string text = TestPdf.Text(pdf.Finish("/Root 2 0 R"));
        long offset = text.IndexOf("\n1 0 obj", StringComparison.Ordinal) + 1;
        byte[] crooked = TestPdf.Latin(text.Replace($"{offset:D10} 00000 n", $"{offset + 3:D10} 00000 n"));
        byte[] signed = PdfSigner.Sign(crooked, SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill });
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] shadowed = [.. signed, .. TestPdf.Latin($"\n1 0 obj\n<</Length {Evil.Length}>>\nstream\n{Evil}\nendstream\nendobj\n")];
        byte[] attacked = PdfSigner.Sign(shadowed, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, FieldName = "Second" });

        Assert.Contains("pay 1,000,000", Encoding.Latin1.GetString(PdfDocument.Open(attacked).Pages[0].Contents()));
        AssertNotAllowed(Check(attacked), SignatureChangeKind.Unreadable);
    }

    [Theory]
    [InlineData("validation")]
    [InlineData("annotation")]
    [InlineData("appearance")]
    public void An_object_that_validation_data_or_a_comment_shares_with_another_job_keeps_the_stricter_one(string role)
    {
        var pdf = role switch
        {
            "validation" => Doc(catalog: "/OpenAction 7 0 R /DSS <</Certs [7 0 R]>>"),
            "annotation" => Doc(catalog: "/OpenAction 6 0 R", page: "/Contents 4 0 R /Annots [6 0 R]"),
            _ => Doc(catalog: "/OpenAction 8 0 R", page: "/Contents 4 0 R /Annots [6 0 R]"),
        };
        pdf.Stream(7, "/S /JavaScript /JS (app.alert\\(1\\))", "x");
        string appearance = role == "appearance" ? "/AP <</N 8 0 R>>" : "";
        if (role != "validation") pdf.Obj(6, $"<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note) /S /JavaScript /JS (app.alert\\(1\\)) {appearance}>>");
        if (role == "appearance") pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 20 20] /S /JavaScript /JS (app.alert\\(1\\))", "x");
        byte[] signed = Sign(pdf, CertificationLevel.Annotate);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d =>
        {
            switch (role)
            {
                case "validation": ((PdfStream)d.Get(7)!).Data = TestPdf.Latin("y"); break;
                case "annotation": ((PdfDictionary)d.Get(6)!)["JS"] = new PdfString(TestPdf.Latin("app.alert(2)"), false); break;
                default: ((PdfStream)d.Get(8)!).Data = TestPdf.Latin("y"); break;
            }
        });

        AssertNotAllowed(Check(attacked));
    }

    [Fact]
    public void Validation_data_named_by_an_object_of_another_kind_frees_nothing()
    {
        var pdf = Doc(catalog: "/DSS <</Certs 6 0 R>> /OCProperties <</D 6 0 R /OCGs []>>");
        pdf.Obj(6, "<</Order [] /BaseState /ON>>");
        byte[] signed = Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(6)!)["BaseState"] = new PdfName("OFF"));

        AssertNotAllowed(Check(attacked));
    }

    [Fact]
    public void A_comment_that_nothing_else_uses_is_still_a_comment_at_level_three()
    {
        var pdf = Doc(page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Text /Rect [10 10 30 30] /Contents (note)>>");
        byte[] signed = Sign(pdf, CertificationLevel.Annotate);

        byte[] edited = SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(6)!)["Contents"] = new PdfString(TestPdf.Latin("changed"), false));

        var report = Check(edited);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Comment && c.Object == 6);
    }

    [Fact]
    public void An_array_that_is_both_annotations_and_page_content_follows_the_content_rule()
    {
        var pdf = Doc(page: "/Contents 6 0 R /Annots 6 0 R");
        pdf.Obj(6, "[4 0 R]");
        byte[] signed = Sign(pdf, CertificationLevel.Annotate);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed,
            (30, $"<</Length {Evil.Length}>>\nstream\n{Evil}\nendstream"),
            (6, "[4 0 R 30 0 R]"));

        Assert.Contains("pay 1,000,000", Encoding.Latin1.GetString(PdfDocument.Open(attacked).Pages[0].Contents()));
        AssertNotAllowed(Check(attacked), SignatureChangeKind.PageContent);
    }

    // The field of a widget kept apart has no /Rect of its own; the stamp is judged on every widget under it.
    private static SignatureChangeReport StampOnField(string widgetRect, bool rewriteAppearance)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 9 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots [7 0 R]>>");
        pdf.Stream(4, "", "BT ET");
        pdf.Obj(6, "<</FT /Sig /T (Late) /Kids [7 0 R]>>");
        pdf.Obj(7, $"<</Type /Annot /Subtype /Widget /Parent 6 0 R {widgetRect} /P 3 0 R /AP <</N 8 0 R>>>>");
        pdf.Stream(8, "/Type /XObject /Subtype /Form /BBox [0 0 90 30]", "0 g");
        pdf.Obj(9, "<</Fields [6 0 R]>>");
        byte[] before = pdf.Finish();

        var update = new List<(int, string)> { (6, "<</FT /Sig /T (Late) /Kids [7 0 R] /V 30 0 R>>"), (30, "<</Type /DocTimeStamp /SubFilter /ETSI.RFC3161>>") };
        if (rewriteAppearance) update.Add((8, "<</Type /XObject /Subtype /Form /BBox [0 0 90 30] /Length 8>>\nstream\n0 0 1 rg\nendstream"));
        byte[] after = SignatureRoleTests.AppendRaw(before, [.. update]);

        var final = PdfDocument.Open(after);
        return ChangeDetector.Compare(PdfDocument.Open(before), final, 1, new HashSet<long> { final.Entries[30].Offset });
    }

    [Fact]
    public void A_time_stamp_in_a_field_whose_widget_shows_something_is_not_allowed_after_a_certification()
    {
        Assert.False(StampOnField("/Rect [10 10 100 40]", rewriteAppearance: true).AllAllowed);
    }

    [Fact]
    public void A_time_stamp_in_a_field_whose_widget_shows_nothing_is_allowed_after_a_certification()
    {
        Assert.True(StampOnField("/Rect [0 0 0 0]", rewriteAppearance: false).AllAllowed);
    }

    [Fact]
    public void Swapping_a_drawn_annotation_with_a_listed_one_changes_the_stacking()
    {
        var pdf = Doc(page: "/Contents 4 0 R /Annots [<</Subtype /Square /Rect [0 0 300 400]>> 6 0 R 8 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40]>>");
        pdf.Obj(8, "<</Type /Annot /Subtype /Text /Rect [100 10 120 30]>>");
        byte[] signed = Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d =>
        {
            var items = d.Array(d.Pages[0].Dictionary, "Annots")!.Items;
            (items[0], items[1]) = (items[1], items[0]);
        });

        AssertNotAllowed(Check(attacked), SignatureChangeKind.Comment);
    }

    [Fact]
    public void A_reference_with_another_generation_is_not_the_same_annotation()
    {
        var pdf = Doc(page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Stamp /Rect [10 10 90 40] /Contents (VOID)>>");
        byte[] signed = Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => d.Array(d.Pages[0].Dictionary, "Annots")!.Items[0] = new PdfReference(6, 3));

        AssertNotAllowed(Check(attacked), SignatureChangeKind.Comment);
    }

    [Fact]
    public void A_reference_with_another_generation_is_not_the_same_field()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.NoChanges);

        byte[] attacked = SignatureChangeTests.Edit(signed, d =>
        {
            var fields = d.Array(d.Dict(d.Catalog, "AcroForm")!, "Fields")!;
            fields.Items[0] = new PdfReference(((PdfReference)fields.Items[0]).Number, 4);
        });

        AssertNotAllowed(Check(attacked), SignatureChangeKind.Form);
    }
}
