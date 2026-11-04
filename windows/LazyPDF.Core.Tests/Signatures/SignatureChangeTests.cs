using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureChangeTests
{
    private static readonly Pki Pki = Pki.Instance;

    /// <summary>Two pages and two text fields, Name and Date.</summary>
    internal static byte[] FormFile()
    {
        var document = PdfDocument.Open(SignatureKit.Plain());
        var form = PdfForm.Read(document);
        form.AddField(new FieldSpec(FieldKind.Text, "Name", 0, new PdfRect(40, 200, 240, 224)));
        form.AddField(new FieldSpec(FieldKind.Text, "Date", 0, new PdfRect(40, 160, 240, 184)));
        return document.SaveIncremental();
    }

    internal static byte[] Certified(CertificationLevel level, FieldLock? fieldLock = null) =>
        PdfSigner.Sign(FormFile(), SignatureKit.Request(Pki) with { Certify = level, Lock = fieldLock });

    internal static byte[] Edit(byte[] file, Action<PdfDocument> change)
    {
        var document = PdfDocument.Open(file);
        change(document);
        return document.SaveIncremental();
    }

    internal static SignatureReport First(byte[] file) => SignatureKit.Verify(file)[0];

    private static byte[] Fill(byte[] file, string field = "Name") =>
        Edit(file, d => PdfForm.Read(d).SetValue(field, "Ada Lovelace"));

    private static void Retitle(PdfDocument document) =>
        (DocumentMetadata.Read(document) with { Title = "New title" }).Write(document);

    private static byte[] Comment(byte[] file) =>
        Edit(file, d => new PdfAnnotationWriter(d).AddNote(d.Pages[0], new PdfRect(250, 350, 270, 370), new AnnotationInfo("A", "Looks fine")));

    [Fact]
    public void A_file_nobody_touched_has_no_changes()
    {
        var report = First(Certified(CertificationLevel.NoChanges));

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.True(report.Changes.IsEmpty);
        Assert.Equal("Signed by Ada Lovelace on 10 Mar 2026. Not changed since.", report.Sentence);
    }

    [Theory]
    [InlineData(CertificationLevel.NoChanges, false)]
    [InlineData(CertificationLevel.FormFill, true)]
    [InlineData(CertificationLevel.Annotate, true)]
    public void Filling_a_form_is_allowed_from_level_two(CertificationLevel level, bool allowed)
    {
        var report = First(Fill(Certified(level)));

        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.NotEmpty(report.Changes.Changes);
        Assert.All(report.Changes.Changes, c => Assert.Equal(SignatureChangeKind.FormFill, c.Kind));
        Assert.All(report.Changes.Changes, c => Assert.Equal(allowed, c.Allowed));
        Assert.Equal("Name", report.Changes.Changes.First(c => c.Field is not null).Field);
        if (allowed) Assert.EndsWith("Changed only as the signer allowed.", report.Sentence);
    }

    [Theory]
    [InlineData(CertificationLevel.NoChanges, false)]
    [InlineData(CertificationLevel.FormFill, false)]
    [InlineData(CertificationLevel.Annotate, true)]
    public void Comments_are_allowed_at_level_three_only(CertificationLevel level, bool allowed)
    {
        var report = First(Comment(Certified(level)));

        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Comment && c.Page == 0 && c.Allowed == allowed);
    }

    [Fact]
    public void Without_certification_only_signatures_and_validation_data_may_follow()
    {
        byte[] signed = PdfSigner.Sign(FormFile(), SignatureKit.Request(Pki));

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(Fill(signed)).Verdict);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(Comment(signed)).Verdict);
        var report = First(PdfSigner.Sign(signed, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain }));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
    }

    [Fact]
    public void Certification_without_changes_refuses_another_signature()
    {
        byte[] certified = Certified(CertificationLevel.NoChanges);
        byte[] second = PdfSigner.Sign(certified, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain });

        var report = First(second);

        Assert.Equal(SignatureKind.Certification, report.Kind);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Signature && !c.Allowed);
    }

    [Fact]
    public void A_certification_at_level_two_takes_a_second_signature()
    {
        byte[] second = PdfSigner.Sign(Certified(CertificationLevel.FormFill), new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain });

        Assert.All(SignatureKit.Verify(second), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
    }

    [Fact]
    public void A_locked_field_stays_locked_whatever_the_level_allows()
    {
        var onlyDate = new FieldLock(FieldLockAction.Exclude, ["Date"]);
        byte[] certified = Certified(CertificationLevel.FormFill, onlyDate);

        Assert.Equal(SignatureVerdict.Valid, First(Fill(certified, "Date")).Verdict);
        var report = First(Fill(certified, "Name"));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Field == "Name" && !c.Allowed);
    }

    [Fact]
    public void A_field_lock_with_Include_and_All_names_what_it_binds()
    {
        var include = Certified(CertificationLevel.FormFill, new FieldLock(FieldLockAction.Include, ["Name"]));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(Fill(include, "Name")).Verdict);
        Assert.Equal(SignatureVerdict.Valid, First(Fill(include, "Date")).Verdict);

        var all = Certified(CertificationLevel.FormFill, new FieldLock(FieldLockAction.All, []));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(Fill(all, "Date")).Verdict);
    }

    [Theory]
    [InlineData(CertificationLevel.FormFill, false)]
    [InlineData(CertificationLevel.Annotate, true)]
    public void A_comment_that_is_removed_again_is_a_comment_change(CertificationLevel level, bool allowed)
    {
        byte[] commented = PdfSigner.Sign(Comment(FormFile()), SignatureKit.Request(Pki) with { Certify = level });
        byte[] removed = Edit(commented, d =>
        {
            var annotation = PdfAnnotations.Read(d, d.Pages[0]).First(a => a.Type == AnnotationType.Text);
            new PdfAnnotationWriter(d).Delete(annotation);
        });

        var report = First(removed);

        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, report.Verdict);
    }

    [Theory]
    [InlineData(CertificationLevel.FormFill)]
    [InlineData(CertificationLevel.Annotate)]
    public void Pages_are_never_allowed_and_metadata_follows_the_level(CertificationLevel level)
    {
        byte[] certified = Certified(level);
        byte[] added = Edit(certified, d => PageOperations.InsertBlank(d, 1, 300, 400));
        var report = First(added);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.PageStructure && !c.Allowed);

        byte[] retitled = Edit(certified, d => Retitle(d));
        Assert.Equal(SignatureVerdict.Valid, First(retitled).Verdict);
        Assert.Contains(First(retitled).Changes.Changes, c => c.Kind == SignatureChangeKind.Metadata);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(Edit(Certified(CertificationLevel.NoChanges), d => Retitle(d))).Verdict);
    }

    [Fact]
    public void Changes_are_listed_in_words()
    {
        var report = First(Fill(Certified(CertificationLevel.FormFill)));

        string[] lines = [.. report.Changes.Changes.Select(SignatureText.Describe)];

        Assert.Contains("Form filled in field Name", lines);
    }

    [Fact]
    public void Revisions_after_the_signature_are_counted()
    {
        byte[] file = Comment(Fill(Certified(CertificationLevel.Annotate)));

        var report = First(file);

        Assert.Equal(2, report.Changes.RevisionsAfter);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.False(report.CoversWholeFile);
    }

    [Fact]
    public void A_file_with_object_streams_and_a_cross_reference_stream_is_judged_the_same_way()
    {
        byte[] packed = PdfDocument.Open(FormFile()).SaveRewrite(new PdfSaveOptions(UseObjectStreams: true));
        Assert.True(PdfDocument.Open(packed).XrefIsStream);
        byte[] certified = PdfSigner.Sign(packed, SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill });
        Assert.Equal(SignatureVerdict.Valid, First(certified).Verdict);
        Assert.Equal(2, PdfRevisions.List(certified).Count);

        Assert.Equal(SignatureVerdict.Valid, First(Fill(certified)).Verdict);
        byte[] attacked = Edit(certified, d => d.Pages[0].Dictionary["Rotate"] = new PdfNumber(90));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(attacked).Verdict);
        byte[] content = Edit(certified, d => ((PdfStream)d.Resolve(d.Pages[0].Dictionary["Contents"])!).Data = TestPdf.Latin("BT ET"));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(content).Verdict);
    }

    [Fact]
    public void A_form_and_annotation_list_that_are_indirect_objects_are_compared_as_objects()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 5 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Contents 4 0 R /Annots 6 0 R>>");
        pdf.Stream(4, "", "BT ET");
        pdf.Obj(5, "<</Fields 7 0 R>>");
        pdf.Obj(6, "[]");
        pdf.Obj(7, "[]");
        byte[] first = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Rect = new PdfRect(10, 10, 100, 40) });
        byte[] second = PdfSigner.Sign(first, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, Rect = new PdfRect(10, 50, 100, 80) });

        var reports = SignatureKit.Verify(second);

        Assert.All(reports, r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
        Assert.Equal(["Signature1", "Signature2"], reports.Select(r => r.FieldName));
        Assert.Contains(reports[0].Changes.Changes, c => c.Kind == SignatureChangeKind.Signature && c.Allowed);

        byte[] hidden = Edit(first, d => d.Array(d.Pages[0].Dictionary, "Annots")!.Items.Clear());
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, First(hidden).Verdict);
    }
}
