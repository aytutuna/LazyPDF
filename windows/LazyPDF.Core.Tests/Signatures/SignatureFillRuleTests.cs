using System.Text;
using LazyPDF.Core;
using Xunit;
using static LazyPDF.Core.Tests.SignatureRawKit;

namespace LazyPDF.Core.Tests;

/// <summary>What filling may touch: the keys a fill writes, the field a widget answers for, pushbuttons, read-only fields, the form's defaults, our own comments and a countersigner's metadata.</summary>
public class SignatureFillRuleTests
{
    private static readonly Pki Pki = Pki.Instance;

    private sealed class Arial : IFontSource
    {
        public FontFile? Find(string family, FontStyles style) =>
            new(File.ReadAllBytes(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf")));
    }

    private static byte[] Sign(TestPdf pdf, FieldLock? fieldLock = null, CertificationLevel level = CertificationLevel.FormFill) =>
        PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = level, Lock = fieldLock });

    private static SignatureReport Fill(byte[] signed, int field) =>
        Check(SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(field)!)["V"] = new PdfString(TestPdf.Latin("1000000"), false)));

    [Fact]
    public void A_widget_with_a_name_of_its_own_is_judged_by_its_own_name_not_its_parents()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [8 0 R]");
        pdf.Obj(6, "<</FT /Tx /T (client)>>");
        pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /T (amount) /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = Sign(pdf, new FieldLock(FieldLockAction.Include, ["client.amount"]));

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Fill(signed, 8).Verdict);
    }

    [Fact]
    public void A_widget_with_flags_of_its_own_that_no_field_lists_is_not_filled()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [8 0 R]");
        pdf.Obj(6, "<</FT /Tx /T (client)>>");
        pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Parent 6 0 R /Ff 1 /V (100) /Rect [20 20 120 40]>>");

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Fill(Sign(pdf), 8).Verdict);
    }

    [Fact]
    public void A_kid_whose_parent_is_not_the_field_that_lists_it_is_judged_by_neither()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R 7 0 R]>>", page: "/Contents 4 0 R /Annots [8 0 R]");
        pdf.Obj(6, "<</FT /Tx /T (client) /Kids [8 0 R]>>");
        pdf.Obj(7, "<</FT /Tx /T (other)>>");
        pdf.Obj(8, "<</Type /Annot /Subtype /Widget /Parent 7 0 R /V (100) /Rect [20 20 120 40]>>");
        byte[] signed = Sign(pdf, new FieldLock(FieldLockAction.Include, ["other"]));

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Fill(signed, 8).Verdict);
    }

    [Theory]
    [InlineData("/FT /Tx", SignatureVerdict.Valid)]
    [InlineData("/FT /Btn /Ff 65536", SignatureVerdict.ChangedAfterSigning)]
    public void A_pushbutton_picture_is_not_a_fill(string type, SignatureVerdict verdict)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm <</Fields [6 0 R]>>", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, $"<</Type /Annot /Subtype /Widget {type} /T (Total) /Rect [20 20 120 40] /AP <</N 9 0 R>>>>");
        pdf.Stream(9, Form, "BT /F1 18 Tf 40 300 Td (Total 100) Tj ET");
        byte[] signed = Sign(pdf);

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (9, StreamBody(Evil, Form)));

        Assert.Equal(verdict, Check(attacked).Verdict);
    }

    private static TestPdf Guarded(string flags)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm 9 0 R", page: "/Contents 4 0 R /Annots [6 0 R]");
        pdf.Obj(6, $"<</Type /Annot /Subtype /Widget /FT /Tx {flags} /T (Amount) /V (100) /Rect [20 20 120 40] /DA (/Helv 12 Tf 0 g)>>");
        pdf.Obj(7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Obj(9, "<</Fields [6 0 R] /DR <</Font <</Helv 7 0 R>>>> /DA (/Helv 12 Tf 0 g)>>");
        return pdf;
    }

    [Theory]
    [InlineData("/Ff 1", "font", false)]
    [InlineData("/Ff 1", "redraw", false)]
    [InlineData("", "font", true)]
    [InlineData("", "redraw", true)]
    public void A_read_only_field_is_not_redrawn_through_the_forms_defaults(string flags, string how, bool allowed)
    {
        byte[] signed = Sign(Guarded(flags));

        byte[] attacked = how == "font"
            ? SignatureRoleTests.AppendRaw(signed, (7, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding <</Differences [49 /nine /nine]>>>>"))
            : SignatureRoleTests.AppendRaw(signed, (9, SignatureUseTests.With(signed, 9, " /NeedAppearances true")));

        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    [Theory]
    [InlineData("LzF1", true)]
    [InlineData("Helv", false)]
    public void A_locked_form_gains_a_font_no_signed_field_names_and_no_other(string name, bool allowed)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm 9 0 R", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40] /DA (/Helv 12 Tf 0 g)>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Note) /Rect [20 60 120 80] /DA (/Helv 12 Tf 0 g)>>");
        pdf.Obj(9, "<</Fields [6 0 R 7 0 R]>>");
        byte[] signed = Sign(pdf, new FieldLock(FieldLockAction.Include, ["Amount"]));

        byte[] attacked = SignatureRoleTests.AppendRaw(signed,
            (9, SignatureUseTests.With(signed, 9, $" /DR <</Font <</{name} 30 0 R>>>>")),
            (30, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>"));

        Assert.Equal(allowed ? SignatureVerdict.Valid : SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    private static byte[] Library(Action<PdfForm> setup, FieldLock? fieldLock = null)
    {
        var document = PdfDocument.Open(SignatureKit.Plain());
        setup(PdfForm.Read(document));
        return PdfSigner.Sign(document.SaveIncremental(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill, Lock = fieldLock });
    }

    private static void AddFields(PdfForm form)
    {
        form.AddField(new FieldSpec(FieldKind.Text, "Name", 0, new PdfRect(40, 200, 240, 224)));
        form.AddField(new FieldSpec(FieldKind.ListBox, "Pick", 0, new PdfRect(40, 100, 240, 160)) { Options = [.. Enumerable.Range(0, 20).Select(i => new FieldOption($"o{i}"))] });
        form.AddField(new FieldSpec(FieldKind.Text, "Rich", 0, new PdfRect(40, 60, 240, 84)));
    }

    [Fact]
    public void Letters_the_forms_font_lacks_are_filled_from_a_new_font()
    {
        byte[] signed = Library(AddFields);

        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d, new Arial()).SetValue("Name", "Şağlık çöğüş"));

        Assert.Equal(SignatureVerdict.Valid, Check(filled).Verdict);
    }

    [Fact]
    public void A_list_box_scrolled_by_a_fill_is_filled()
    {
        byte[] signed = Library(AddFields);

        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Pick", "o15"));

        Assert.Equal(SignatureVerdict.Valid, Check(filled).Verdict);
    }

    [Fact]
    public void A_rich_text_value_is_replaced_by_a_fill()
    {
        byte[] signed = Library(form =>
        {
            AddFields(form);
            form.Find("Rich")!.Dictionary["RV"] = PdfText.ToObject("<body><p>old</p></body>");
        });

        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Rich", "new"));

        Assert.Equal(SignatureVerdict.Valid, Check(filled).Verdict);
    }

    [Fact]
    public void A_fill_of_one_field_does_not_need_the_form_to_be_unlocked()
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/AcroForm 9 0 R", page: "/Contents 4 0 R /Annots [6 0 R 7 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /V (100) /Rect [20 20 120 40]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Note) /Rect [20 60 120 80]>>");
        pdf.Obj(9, "<</Fields [6 0 R 7 0 R]>>");
        byte[] signed = Sign(pdf, new FieldLock(FieldLockAction.Include, ["Amount"]));

        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Note", "Ada"));

        var report = Check(filled);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
    }

    [Theory]
    [InlineData("caret")]
    [InlineData("redact")]
    public void Marks_our_own_writer_makes_are_comments(string kind)
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate });

        byte[] marked = SignatureChangeTests.Edit(signed, d =>
        {
            var writer = new PdfAnnotationWriter(d);
            if (kind == "caret") writer.AddCaret(d.Pages[0], new PdfRect(100, 100, 110, 112), new AnnotationInfo("A", "insert"));
            else writer.AddRedact(d.Pages[0], [MarkupQuad.FromRect(new PdfRect(100, 600, 200, 614))], new AnnotationInfo("A"), [0, 0, 0], "REDACTED");
        });

        Assert.Equal(SignatureVerdict.Valid, Check(marked).Verdict);
    }

    private const string Xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
        + "<rdf:Description xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmp:CreatorTool=\"{0}\" xmp:ModifyDate=\"{1}\" rdf:about=\"\" pdf:Producer=\"{2}\"/>"
        + "</rdf:RDF></x:xmpmeta><?xpacket end=\"r\"?>";

    [Theory]
    [InlineData("Word", "2026-11-04T12:18:19-05:00", "Writer 2", SignatureVerdict.Valid)]
    [InlineData("Other", "2026-11-04T12:18:19-05:00", "Writer 1", SignatureVerdict.ChangedAfterSigning)]
    public void A_packet_that_only_restamps_its_dates_and_producer_passes_below_level_two(string tool, string date, string producer, SignatureVerdict verdict)
    {
        var pdf = SignatureSharedRoleTests.Doc(catalog: "/Metadata 6 0 R");
        pdf.Stream(6, "/Type /Metadata /Subtype /XML", string.Format(Xmp, "Word", "2026-11-04T12:18:17-05:00", "Writer 1"));
        byte[] signed = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki));

        byte[] attacked = SignatureRoleTests.AppendRaw(signed, (6, StreamBody(string.Format(Xmp, tool, date, producer), "/Type /Metadata /Subtype /XML")));

        Assert.Equal(verdict, Check(attacked).Verdict);
    }
}
