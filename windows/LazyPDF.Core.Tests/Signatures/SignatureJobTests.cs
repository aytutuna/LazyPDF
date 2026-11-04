using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>What an object is used for decides what may change in it: designs that name fields without using them, and objects that serve twice.</summary>
public class SignatureJobTests
{
    private static byte[] Fill(byte[] signed, int field) =>
        SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(field)!)["V"] = new PdfString(TestPdf.Latin("200"), false));

    private static TestPdf Form(string catalog = "", string widget = "")
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: $"/AcroForm <</Fields [6 0 R 7 0 R]>> {catalog}", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        pdf.Obj(7, $"<</Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (Send) /Rect [20 60 120 80] {widget}>>");
        return pdf;
    }

    [Theory]
    [InlineData("/A <</S /ResetForm /Fields [6 0 R]>>")]
    [InlineData("/A <</S /SubmitForm /F <</FS /URL /F (http://x)>> /Fields [6 0 R]>>")]
    [InlineData("/A <</S /Hide /T 6 0 R /H true>>")]
    [InlineData("/AA <</U <</S /ResetForm /Fields [6 0 R]>>>>")]
    public void A_field_that_a_button_only_names_can_be_filled(string action)
    {
        byte[] signed = SignatureSharedRoleTests.Sign(Form(widget: action), CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        var report = Check(Fill(signed, 6));

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 6);
    }

    [Fact]
    public void A_field_that_the_calculation_order_names_can_be_filled()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(CalculatedForm(), CertificationLevel.FormFill);

        Assert.Equal(SignatureVerdict.Valid, Check(Fill(signed, 6)).Verdict);
    }

    private static TestPdf CalculatedForm()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R] /CO [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        return pdf;
    }

    [Fact]
    public void A_field_that_something_else_uses_is_not_filled_by_that_permission()
    {
        byte[] signed = SignatureSharedRoleTests.Sign(Form(catalog: "/OpenAction <</S /Named /N 6 0 R>>"), CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        var report = Check(Fill(signed, 6));

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == 6);
    }

    [Fact]
    public void A_tagged_form_is_filled_though_the_structure_tree_names_its_widgets_and_page()
    {
        var pdf = Form(catalog: "/StructTreeRoot 8 0 R");
        pdf.Obj(8, "<</Type /StructTreeRoot /K 9 0 R>>");
        pdf.Obj(9, "<</Type /StructElem /S /Form /P 8 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 6 0 R /Pg 3 0 R>>>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        var report = Check(Fill(signed, 6));

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill && c.Object == 6);
    }

    [Fact]
    public void The_structure_tree_itself_cannot_change()
    {
        var pdf = Form(catalog: "/StructTreeRoot 8 0 R");
        pdf.Obj(8, "<</Type /StructTreeRoot /K 9 0 R>>");
        pdf.Obj(9, "<</Type /StructElem /S /Form /P 8 0 R /Pg 3 0 R /K <</Type /OBJR /Obj 6 0 R /Pg 3 0 R>>>>");
        byte[] signed = SignatureSharedRoleTests.Sign(pdf, CertificationLevel.Annotate);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(9)!)["S"] = new PdfName("Figure"));

        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == 9);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(3)]
    public void An_annotation_the_signed_bytes_hold_unlisted_is_not_woken_by_defining_the_list_that_was_missing(int level)
    {
        var pdf = SignatureSharedRoleTests.Doc(page: "/Contents 4 0 R /Annots 7 0 R");
        pdf.Obj(8, "<</Type /Annot /Subtype /Stamp /Rect [0 0 300 400] /AP <</N 9 0 R>>>>");
        pdf.Stream(9, SignatureRawKit.Form, "0 g");
        byte[] before = pdf.Finish();
        byte[] after = SignatureRoleTests.AppendRaw(before, (7, "[8 0 R]"));

        var report = SignatureOverlapTests.Compare(before, after, level);

        Assert.Contains(report.NotAllowed, c => c.Object == 8);
    }

    [Fact]
    public void A_signed_revision_with_the_catalog_in_the_trailer_accepts_no_update()
    {
        byte[] before = TestPdf.WithPages(1).Finish("/Root <</Type /Catalog /Pages 2 0 R>>");
        var document = PdfDocument.Open(before);
        string trailer = $"<</Size {document.NextObjectNumber} /Root <</Type /Catalog /Pages 2 0 R>> /Prev {document.StartXref}>>";
        byte[] after = [.. before, .. TestPdf.Latin($"xref\n0 1\n0000000000 65535 f \ntrailer\n{trailer}\nstartxref\n{before.Length}\n%%EOF\n")];

        Assert.Contains(SignatureOverlapTests.Compare(before, after, 1).NotAllowed, c => c.Kind == SignatureChangeKind.Unreadable);
    }

    [Fact]
    public void Updates_the_edit_session_commits_are_read_as_the_level_allows_and_undo_takes_them_back()
    {
        var session = PdfEditSession.Open(SignatureChangeTests.Certified(CertificationLevel.Annotate));
        new PdfAnnotationWriter(session.Document).AddNote(session.Document.Pages[0], new PdfRect(250, 350, 270, 370), new AnnotationInfo("A", "one"));
        session.Commit("Comment");
        PdfForm.Read(session.Document).SetValue("Name", "Ada");
        session.Commit("Fill");

        var report = SignatureKit.Verify(session.Current.ToArray())[0];
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.Comment);
        Assert.Contains(report.Changes.Changes, c => c.Kind == SignatureChangeKind.FormFill);

        session.Undo();
        session.Undo();
        Assert.True(SignatureKit.Verify(session.Current.ToArray())[0].Changes.IsEmpty);
    }

    [Fact]
    public void Damaged_updates_never_crash_the_verifier()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);
        byte[] original = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Name", "Ada"));
        var random = new Random(23);
        for (int round = 0; round < 400; round++)
        {
            byte[] copy = (byte[])original.Clone();
            for (int k = random.Next(1, 4); k > 0; k--) copy[random.Next(signed.Length, copy.Length)] = (byte)random.Next(256);
            if (round % 8 == 0) copy = copy.AsSpan(0, random.Next(signed.Length, copy.Length)).ToArray();
            try
            {
                foreach (var report in SignatureKit.Verify(copy)) _ = report.Sentence;
            }
            catch (PdfReadException)
            {
            }
        }
    }
}
