using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>What a later revision makes a reader show decides the verdict, however the change is dressed up.</summary>
public class SignatureRoleTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static SignatureReport Check(byte[] file) => SignatureKit.Verify(file)[0];

    private static void AssertChanged(SignatureReport report, SignatureChangeKind? kind = null)
    {
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        if (kind is { } k) Assert.Contains(report.Changes.NotAllowed, c => c.Kind == k);
    }

    // A text field whose appearance stream (7) uses the font (5) that the page text uses too.
    private static byte[] SharedFont(CertificationLevel level, PdfRect? rect = null)
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R /AcroForm 8 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R /Annots [6 0 R]>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [20 20 200 50] /P 3 0 R /AP <</N 7 0 R>>>>");
        pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 180 30] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 12 Tf 2 8 Td (x) Tj ET");
        pdf.Obj(8, "<</Fields [6 0 R]>>");
        return PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = level, Rect = rect });
    }

    [Fact]
    public void A_font_used_by_the_page_and_by_a_field_follows_the_stricter_rule()
    {
        byte[] signed = SharedFont(CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(5)!)["BaseFont"] = new PdfName("Courier"));

        AssertChanged(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Fact]
    public void The_appearance_of_a_signed_signature_field_cannot_be_replaced()
    {
        foreach (var level in new[] { CertificationLevel.None, CertificationLevel.FormFill, CertificationLevel.Annotate })
        {
            byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Certify = level, Rect = new PdfRect(20, 20, 200, 60) });
            Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

            byte[] attacked = SignatureChangeTests.Edit(signed, d =>
            {
                var field = PdfForm.Read(d).Fields.First(f => f.Kind == FieldKind.Signature);
                var normal = (PdfStream)d.Resolve(d.Dict(field.Widgets[0].Dictionary, "AP")!["N"])!;
                normal.Data = TestPdf.Latin("0 g 0 0 100 30 re f");
            });

            AssertChanged(Check(attacked));
        }
    }

    [Fact]
    public void An_object_the_update_calls_validation_data_is_still_judged_by_what_it_is()
    {
        byte[] signed = SharedFont(CertificationLevel.NoChanges);

        byte[] attacked = SignatureChangeTests.Edit(signed, d =>
        {
            d.Catalog["DSS"] = new PdfDictionary { ["X"] = new PdfReference(7, 0) };
            ((PdfStream)d.Get(7)!).Data = TestPdf.Latin("BT /F1 12 Tf 2 8 Td (forged) Tj ET");
        });

        AssertChanged(Check(attacked));
    }

    [Fact]
    public void A_dangling_content_reference_cannot_be_filled_through_the_validation_data()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents [4 0 R 9 0 R]>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        byte[] signed = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate });
        var evil = TestPdf.Latin("BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET");

        byte[] viaDss = SignatureChangeTests.Edit(signed, d =>
        {
            d.Set(9, new PdfStream(new PdfDictionary(), evil));
            d.Catalog["DSS"] = new PdfDictionary { ["X"] = new PdfReference(9, 0) };
        });
        byte[] viaEdit = SignatureChangeTests.Edit(signed, d =>
        {
            d.Set(9, new PdfStream(new PdfDictionary(), evil));
            new PdfAnnotationWriter(d).AddNote(d.Pages[0], new PdfRect(250, 350, 270, 370), new AnnotationInfo("A", "note"));
        });

        Assert.Contains("pay 1,000,000", Encoding.Latin1.GetString(PdfDocument.Open(viaDss).Pages[0].Contents()));
        AssertChanged(Check(viaDss));
        AssertChanged(Check(viaEdit));
    }

    private static PdfDictionary FakeSignatureWidget(PdfDocument d, PdfObject? value)
    {
        var form = new PdfStream(new PdfDictionary
        {
            ["Type"] = new PdfName("XObject"),
            ["Subtype"] = new PdfName("Form"),
            ["BBox"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(300), new PdfNumber(400)]),
        }, TestPdf.Latin("0 g 0 0 300 400 re f"));
        var widget = new PdfDictionary
        {
            ["Type"] = new PdfName("Annot"),
            ["Subtype"] = new PdfName("Widget"),
            ["FT"] = new PdfName("Sig"),
            ["T"] = PdfText.ToObject("Late"),
            ["Rect"] = new PdfRect(0, 0, 300, 400).ToArray(),
            ["P"] = d.Pages[0].Reference!,
            ["AP"] = new PdfDictionary { ["N"] = d.Add(form) },
        };
        if (value is not null) widget["V"] = value;
        return widget;
    }

    [Theory]
    [InlineData(CertificationLevel.NoChanges, true)]
    [InlineData(CertificationLevel.FormFill, false)]
    [InlineData(CertificationLevel.Annotate, false)]
    [InlineData(CertificationLevel.None, false)]
    public void A_signature_widget_without_a_signature_behind_it_is_not_allowed(CertificationLevel level, bool stamp)
    {
        byte[] signed = level == CertificationLevel.None
            ? PdfSigner.Sign(SignatureChangeTests.FormFile(), SignatureKit.Request(Pki))
            : SignatureChangeTests.Certified(level);

        byte[] attacked = SignatureChangeTests.Edit(signed, d =>
        {
            PdfObject? value = stamp ? new PdfDictionary { ["Type"] = new PdfName("DocTimeStamp") } : level == CertificationLevel.None ? null : new PdfDictionary { ["Type"] = new PdfName("Sig") };
            var widget = d.Add(FakeSignatureWidget(d, value));
            d.Array(d.Pages[0].Dictionary, "Annots")!.Items.Add(widget);
            d.Array(d.Dict(d.Catalog, "AcroForm")!, "Fields")!.Items.Add(widget);
        });

        AssertChanged(Check(attacked));
    }

    [Fact]
    public void A_real_time_stamp_is_allowed_after_a_certification_without_changes_only_when_it_shows_nothing()
    {
        byte[] certified = SignatureChangeTests.Certified(CertificationLevel.NoChanges);
        byte[] stamped = PdfSigner.AddDocumentTimestamp(certified, new TimestampSettings(new FakeNetwork(), "http://tsa.test/"), Pki.Signing.AddDays(1));
        Assert.Equal(SignatureVerdict.Valid, Check(stamped).Verdict);

        // Same width, so every offset stays; the stamp itself no longer matches, which is its own report's business.
        string text = TestPdf.Text(stamped);
        int at = text.LastIndexOf("/Rect [0 0 0 0]", StringComparison.Ordinal);
        Assert.True(at > 0);
        byte[] visible = (byte[])stamped.Clone();
        TestPdf.Latin("/Rect [0 0 9 9]").CopyTo(visible, at);

        AssertChanged(Check(visible), SignatureChangeKind.Signature);
    }

    [Fact]
    public void A_second_signature_with_a_real_byte_range_is_still_allowed()
    {
        byte[] second = PdfSigner.Sign(SignatureChangeTests.Certified(CertificationLevel.FormFill), new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, Rect = new PdfRect(10, 10, 100, 40) });

        Assert.All(SignatureKit.Verify(second), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
    }

    [Fact]
    public void A_pending_field_filled_with_a_fake_signature_value_is_not_allowed()
    {
        var empty = PdfDocument.Open(SignatureKit.Plain());
        PdfForm.Read(empty).AddField(new FieldSpec(FieldKind.Signature, "Later", 0, new PdfRect(10, 10, 100, 40)));
        byte[] prepared = PdfSigner.Sign(empty.SaveIncremental(), SignatureKit.Request(Pki));
        Assert.Equal(SignatureVerdict.Valid, Check(prepared).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(prepared, d =>
        {
            var field = PdfForm.Read(d).Find("Later")!;
            field.Dictionary["V"] = d.Add(new PdfDictionary { ["Type"] = new PdfName("DocTimeStamp") });
        });

        AssertChanged(Check(attacked));
    }

    // Objects written as they are, in an update of their own: the library writes the last of a repeated key only.
    internal static byte[] AppendRaw(byte[] file, params (int Number, string Body)[] objects)
    {
        var document = PdfDocument.Open(file);
        var text = new StringBuilder("\n");
        var offsets = new List<(int, long)>();
        foreach (var (number, body) in objects)
        {
            offsets.Add((number, file.Length + text.Length));
            text.Append($"{number} 0 obj\n{body}\nendobj\n");
        }
        long xref = file.Length + text.Length;
        text.Append("xref\n");
        foreach (var (number, offset) in offsets.OrderBy(o => o.Item1)) text.Append($"{number} 1\n{offset:D10} 00000 n \n");
        text.Append($"trailer\n<</Size {Math.Max(document.NextObjectNumber, objects.Max(o => o.Number) + 1)} {SignatureRawKit.Kept(document)} /Prev {document.StartXref}>>\nstartxref\n{xref}\n%%EOF\n");
        return [.. file, .. TestPdf.Latin(text.ToString())];
    }

    [Fact]
    public void A_page_dictionary_with_a_repeated_key_is_not_the_same_dictionary()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);
        var page = PdfDocument.Open(signed).Pages[0];
        string original = page.Dictionary.ToString()!;

        byte[] attacked = AppendRaw(signed,
            (50, "<</Length 22>>\nstream\nBT /F1 9 Tf (evil) Tj ET\nendstream"),
            (page.Reference!.Number, "<</Contents 50 0 R " + original[2..]));

        Assert.Equal(PdfDocument.Open(signed).Pages[0].Contents(), PdfDocument.Open(attacked).Pages[0].Contents());
        AssertChanged(Check(attacked));
    }

    [Theory]
    [InlineData("page")]
    [InlineData("widget")]
    [InlineData("stamp")]
    public void An_object_freed_while_something_still_points_at_it_is_reported(string what)
    {
        byte[] signed = what == "stamp"
            ? PdfSigner.Sign(SignatureChangeTests.Edit(SignatureChangeTests.FormFile(), d => new PdfAnnotationWriter(d).AddStamp(d.Pages[0], new PdfRect(30, 280, 270, 330), "VOID")),
                SignatureKit.Request(Pki) with { Certify = CertificationLevel.NoChanges })
            : SignatureChangeTests.Certified(CertificationLevel.NoChanges);
        var document = PdfDocument.Open(signed);
        int target = what switch
        {
            "page" => document.Pages[1].Reference!.Number,
            "widget" => PdfForm.Read(document).Find("Name")!.Reference!.Number,
            _ => PdfAnnotations.Read(document, document.Pages[0]).First(a => a.Type == AnnotationType.Stamp).Reference!.Number,
        };

        byte[] attacked = SignatureChangeTests.Edit(signed, d => d.Delete(target));

        AssertChanged(Check(attacked));
    }
}

