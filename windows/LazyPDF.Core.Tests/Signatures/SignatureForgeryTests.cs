using System.Formats.Asn1;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Updates that borrow, shadow or reorder what a signature covers, and revocation data that says less than it seems to.</summary>
public class SignatureForgeryTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static readonly byte[] Evil = TestPdf.Latin("BT /F1 18 Tf 40 300 Td (Contract page 1: pay 1,000,000) Tj ET");

    private static SignatureReport Check(byte[] file) => SignatureKit.Verify(file)[0];

    private static byte[] Sign(TestPdf pdf, CertificationLevel level, FieldLock? fieldLock = null) =>
        PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = level, Lock = fieldLock });

    private static string ViewerText(byte[] file) => Encoding.Latin1.GetString(PdfDocument.Open(file).Pages[0].Contents());

    // A page with the font of the other tests; each test adds what it needs from number 6 on.
    private static TestPdf Base(string catalog = "", string pages = "", string page = "")
    {
        var pdf = new TestPdf();
        pdf.Obj(1, $"<</Type /Catalog /Pages 2 0 R {catalog}>>");
        pdf.Obj(2, $"<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400] {pages}>>");
        pdf.Obj(3, $"<</Type /Page /Parent 2 0 R /Contents 4 0 R {page}>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        return pdf;
    }

    internal static byte[] AppendSection(byte[] signed, string objects, string entries)
    {
        var document = PdfDocument.Open(signed);
        var text = new StringBuilder("\n" + objects);
        long xref = signed.Length + text.Length;
        text.Append($"xref\n{entries}trailer\n<</Size {document.NextObjectNumber} /Root 1 0 R /Prev {document.StartXref}>>\nstartxref\n{xref}\n%%EOF\n");
        return [.. signed, .. TestPdf.Latin(text.ToString())];
    }

    private static string StreamObject(int number, string body) => $"{number} 0 obj\n<</Length {body.Length}>>\nstream\n{body}\nendstream\nendobj\n";

    private static void AssertChanged(SignatureReport report, SignatureChangeKind kind)
    {
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == kind);
    }

    // ---- a signature that is not new

    [Theory]
    [InlineData(CertificationLevel.FormFill, true)]
    [InlineData(CertificationLevel.Annotate, true)]
    [InlineData(CertificationLevel.FormFill, false)]
    [InlineData(CertificationLevel.Annotate, false)]
    public void A_widget_that_points_at_the_signed_signature_is_not_a_new_signature(CertificationLevel level, bool listedInForm)
    {
        byte[] signed = SignatureChangeTests.Certified(level);

        byte[] attacked = SignatureChangeTests.Edit(signed, d =>
        {
            var victim = PdfForm.Read(d).Fields.First(f => f.Kind == FieldKind.Signature);
            var widget = d.Add(new PdfDictionary
            {
                ["Type"] = new PdfName("Annot"),
                ["Subtype"] = new PdfName("Widget"),
                ["FT"] = new PdfName("Sig"),
                ["T"] = new PdfString(Encoding.ASCII.GetBytes("Cover"), false),
                ["Rect"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(300), new PdfNumber(400)]),
                ["V"] = victim.Dictionary["V"]!,
            });
            d.Array(d.Pages[0].Dictionary, "Annots")!.Items.Add(widget);
            if (listedInForm) d.Array(d.Dict(d.Catalog, "AcroForm"), "Fields")!.Items.Add(widget);
        });

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    [Fact]
    public void A_widget_that_only_names_the_signed_field_as_its_parent_is_not_a_new_signature()
    {
        byte[] attacked = SignatureChangeTests.Edit(SignatureChangeTests.Certified(CertificationLevel.Annotate), d =>
        {
            var victim = PdfForm.Read(d).Fields.First(f => f.Kind == FieldKind.Signature);
            var widget = d.Add(new PdfDictionary
            {
                ["Type"] = new PdfName("Annot"),
                ["Subtype"] = new PdfName("Widget"),
                ["Parent"] = victim.Reference!,
                ["Rect"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(300), new PdfNumber(400)]),
            });
            d.Array(d.Pages[0].Dictionary, "Annots")!.Items.Add(widget);
        });

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    [Fact]
    public void A_second_signature_added_by_signing_again_is_still_a_new_signature()
    {
        byte[] second = PdfSigner.Sign(SignatureChangeTests.Certified(CertificationLevel.FormFill), new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain });

        Assert.All(SignatureKit.Verify(second), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
    }

    [Fact]
    public void A_signature_whose_contents_are_no_signature_does_not_count_as_added()
    {
        byte[] second = PdfSigner.Sign(SignatureChangeTests.Certified(CertificationLevel.FormFill), new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain });
        byte[] garbled = (byte[])second.Clone();
        var range = ((PdfArray)SignatureScan.Find(garbled)[1].Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        Array.Fill(garbled, (byte)'0', range[1] + 1, range[2] - range[1] - 2);
        Encoding.ASCII.GetBytes(Convert.ToHexString(new byte[40]), garbled.AsSpan(range[1] + 1));

        var reports = SignatureKit.Verify(garbled);

        Assert.Equal(SignatureVerdict.Broken, reports[1].Verdict);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, reports[0].Verdict);
    }

    // ---- objects the signed revision could not read

    [Fact]
    public void An_entry_past_the_end_of_the_signed_revision_cannot_be_filled_in_later()
    {
        var pdf = Base(page: "").Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents [4 0 R 9 0 R]>>");
        byte[] file = TestPdf.Replace(TestPdf.Replace(pdf.Finish(), "xref\n0 6\n", "xref\n0 10\n"), "trailer\n<</Size 6",
            "0000000000 00000 f \n0000000000 00000 f \n0000000000 00000 f \n0000200000 00000 n \ntrailer\n<</Size 10");
        byte[] signed = PdfSigner.Sign(file, SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate });
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] padded = [.. signed, .. Enumerable.Repeat((byte)' ', 199_999 - signed.Length)];
        byte[] attacked = AppendSection(padded, StreamObject(9, Encoding.Latin1.GetString(Evil)), "");

        Assert.Contains("pay 1,000,000", ViewerText(attacked));
        AssertChanged(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Fact]
    public void A_stream_that_only_ends_past_the_signed_revision_cannot_grow_later()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET", length: 200_000, endstream: false);
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        byte[] signed = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate });
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        long end = PdfDocument.Open(signed).Get(4) is PdfStream stream ? stream.DataOffset + 200_000 : 0;
        var tail = new List<byte>(TestPdf.Latin("\n"));
        tail.AddRange(Enumerable.Repeat((byte)' ', (int)(end - signed.Length - 1 - Evil.Length)));
        tail.AddRange(Evil);
        byte[] grown = [.. signed, .. tail, .. TestPdf.Latin("\nendstream\nendobj\n")];
        byte[] attacked = AppendSection(grown, "", "");

        Assert.Contains("pay 1,000,000", ViewerText(attacked));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    // ---- direct entries of /Annots

    private static byte[] DirectAnnots(CertificationLevel level)
    {
        var pdf = Base(page: "/Annots [<</Subtype /Square /Rect [0 0 1 1]>>]");
        return Sign(pdf, level);
    }

    [Theory]
    [InlineData(CertificationLevel.NoChanges)]
    [InlineData(CertificationLevel.FormFill)]
    public void A_direct_annotation_swapped_for_another_is_a_comment(CertificationLevel level)
    {
        byte[] attacked = SignatureChangeTests.Edit(DirectAnnots(level), d =>
        {
            var cover = new PdfDictionary
            {
                ["Subtype"] = new PdfName("FreeText"),
                ["Rect"] = new PdfArray([new PdfNumber(0), new PdfNumber(0), new PdfNumber(300), new PdfNumber(400)]),
                ["Contents"] = new PdfString(Encoding.ASCII.GetBytes("VOID"), false),
            };
            d.Array(d.Pages[0].Dictionary, "Annots")!.Items[0] = cover;
        });

        AssertChanged(Check(attacked), SignatureChangeKind.Comment);
    }

    [Fact]
    public void Reordering_the_annotations_of_a_page_changes_what_is_on_top()
    {
        var pdf = Base(page: "/Annots [6 0 R 7 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Circle /Rect [0 0 50 50]>>");
        byte[] signed = Sign(pdf, CertificationLevel.FormFill);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => d.Array(d.Pages[0].Dictionary, "Annots")!.Items.Reverse());

        AssertChanged(Check(attacked), SignatureChangeKind.Comment);
    }

    [Fact]
    public void Reordering_the_annotations_is_a_comment_that_level_three_allows()
    {
        var pdf = Base(page: "/Annots [6 0 R 7 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Square /Rect [0 0 50 50]>>");
        pdf.Obj(7, "<</Type /Annot /Subtype /Circle /Rect [0 0 50 50]>>");
        byte[] signed = Sign(pdf, CertificationLevel.Annotate);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => d.Array(d.Pages[0].Dictionary, "Annots")!.Items.Reverse());

        Assert.Equal(SignatureVerdict.Valid, Check(attacked).Verdict);
    }

    // ---- which rule an object that serves twice follows

    [Fact]
    public void A_stream_that_is_metadata_and_page_content_follows_the_page_content_rule()
    {
        byte[] signed = Sign(Base(catalog: "/Metadata 4 0 R"), CertificationLevel.FormFill);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfStream)d.Get(4)!).Data = Evil);

        AssertChanged(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Fact]
    public void A_stream_that_is_page_content_and_listed_as_an_annotation_follows_the_page_content_rule()
    {
        byte[] signed = Sign(Base(page: "/Annots [4 0 R]"), CertificationLevel.Annotate);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfStream)d.Get(4)!).Data = Evil);

        AssertChanged(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void A_signed_field_replaced_by_something_that_is_no_dictionary_is_caught(bool stream)
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);

        byte[] attacked = SignatureChangeTests.Edit(signed, d =>
        {
            var field = PdfForm.Read(d).Fields.First(f => f.Kind == FieldKind.Signature);
            d.Set(field.Reference!.Number, stream ? new PdfStream(field.Dictionary.Copy(), Evil) : PdfNull.Instance);
        });

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    [Fact]
    public void Resources_a_page_inherits_are_page_content()
    {
        var pdf = Base(catalog: "/AcroForm <</Fields [6 0 R]>>", pages: "/Resources <</Font <</F1 5 0 R>>>>", page: "/Annots [6 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Free) /Rect [20 20 120 40] /AP <</N 7 0 R>>>>");
        pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 100 20] /Resources <</Font <</F1 5 0 R>>>>", "BT /F1 10 Tf (x) Tj ET");
        byte[] signed = Sign(pdf, CertificationLevel.FormFill);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(5)!)["BaseFont"] = new PdfName("Courier"));

        AssertChanged(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Fact]
    public void An_appearance_two_fields_share_follows_the_stricter_field()
    {
        var pdf = Base(catalog: "/AcroForm <</Fields [6 0 R 8 0 R]>>", page: "/Annots [6 0 R 8 0 R]");
        pdf.Obj(6, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Free) /Rect [20 20 120 40] /AP <</N 7 0 R>>>>");
        pdf.Stream(7, "/Type /XObject /Subtype /Form /BBox [0 0 100 20]", "BT /F1 10 Tf (1) Tj ET");
        pdf.Obj(8, "<</Type /Annot /Subtype /Widget /FT /Tx /T (Amount) /Rect [20 60 120 80] /AP <</N 7 0 R>>>>");
        byte[] signed = Sign(pdf, CertificationLevel.FormFill, new FieldLock(FieldLockAction.Include, ["Amount"]));
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfStream)d.Get(7)!).Data = TestPdf.Latin("BT /F1 10 Tf (999999) Tj ET"));

        AssertChanged(Check(attacked), SignatureChangeKind.FormFill);
    }

    // ---- validation data

    [Fact]
    public void Only_the_data_a_DSS_names_may_change_as_validation_data()
    {
        var pdf = Base(catalog: "/DSS <</X 6 0 R>> /OCProperties <</OCGs [7 0 R] /D 6 0 R>>");
        pdf.Obj(6, "<</Order [7 0 R]>>");
        pdf.Obj(7, "<</Type /OCG /Name (Layer)>>");
        byte[] signed = Sign(pdf, CertificationLevel.NoChanges);
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => ((PdfDictionary)d.Get(6)!)["OFF"] = new PdfArray([new PdfReference(7, 0)]));

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    // ---- shadows in the update

    private static (byte[] Signed, int Content, long Offset) Certified()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);
        var document = PdfDocument.Open(signed);
        int content = ((PdfReference)document.Pages[0].Dictionary["Contents"]!).Number;
        return (signed, content, document.Entries[content].Offset);
    }

    [Theory]
    [InlineData(3)]
    [InlineData(999_999)]
    public void A_stream_that_claims_more_length_than_it_has_hides_nothing(int length)
    {
        var (signed, content, _) = Certified();
        long offset = signed.Length + 1;
        string objects = $"60 0 obj\n<</Length {length}>>\nstream\nabc\nendstream\nendobj\n" + StreamObject(content, Encoding.Latin1.GetString(Evil));

        byte[] attacked = AppendSection(signed, objects, $"60 1\n{offset:D10} 00000 n \n");

        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.PageContent && c.Object == content);
    }

    [Fact]
    public void An_entry_listed_once_and_taken_back_later_does_not_whitelist_the_shadow()
    {
        var (signed, content, original) = Certified();
        long shadow = signed.Length + 1;
        byte[] first = AppendSection(signed, StreamObject(content, Encoding.Latin1.GetString(Evil)), $"{content} 1\n{shadow:D10} 00000 n \n");
        byte[] attacked = AppendSection(first, "", $"{content} 1\n{original:D10} 00000 n \n");

        Assert.DoesNotContain("pay 1,000,000", ViewerText(attacked));
        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == content);
    }

    [Fact]
    public void A_header_with_leading_zeros_is_still_a_header()
    {
        var (signed, content, _) = Certified();
        string body = Encoding.Latin1.GetString(Evil);
        string shadow = $"{content:D12} 0 obj\n<</Length {body.Length}>>\nstream\n{body}\nendstream\nendobj\n";

        byte[] attacked = AppendSection(signed, shadow, "");

        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == content);
    }

    [Fact]
    public void A_byte_range_with_a_huge_offset_is_refused_without_throwing()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);
        byte[] attacked = [.. signed, .. TestPdf.Latin("\n60 0 obj\n<</Type /Sig /ByteRange [0 9223372036854775807 100 50] /Contents <00>>>\nendobj\n")];

        var reports = SignatureKit.Verify(attacked);

        Assert.Equal(SignatureVerdict.Valid, reports[0].Verdict);
    }

    // ---- revocation data

    private static X509Extension Distribution(bool directory)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
        using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
        {
            if (directory)
            {
                using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 4))) w.WriteEncodedValue(new X500DistinguishedName("CN=Partition 7").RawData);
            }
            else
            {
                w.WriteCharacterString(UniversalTagNumber.IA5String, Pki.CrlUrl, new Asn1Tag(TagClass.ContextSpecific, 6));
            }
        }
        return new X509Extension("2.5.29.28", w.Encode(), true);
    }

    private static X509Extension Delta()
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        w.WriteInteger(1);
        return new X509Extension("2.5.29.27", w.Encode(), true);
    }

    private static RevocationState About(FakeNetwork network) =>
        Crl.Parse(network.Get(Pki.CrlUrl)!)!.About(Pki.Leaf, Pki.Intermediate).State;

    [Fact]
    public void A_delta_list_that_names_the_certificate_says_it_is_revoked()
    {
        Assert.Equal(RevocationState.Revoked, About(new FakeNetwork { Revoked = true, CrlExtension = Delta() }));
        Assert.Equal(RevocationState.NoData, About(new FakeNetwork { CrlExtension = Delta() }));
    }

    [Fact]
    public void A_list_for_a_partition_named_by_a_directory_name_is_not_complete()
    {
        Assert.Equal(RevocationState.NoData, About(new FakeNetwork { CrlExtension = Distribution(directory: true) }));
        Assert.Equal(RevocationState.Good, About(new FakeNetwork { CrlExtension = Distribution(directory: false) }));
    }

    [Fact]
    public void An_ocsp_responder_whose_certificate_had_expired_when_it_answered_says_nothing()
    {
        using var responder = Pki.Issued("Responder", X509KeyUsageFlags.DigitalSignature, "1.3.6.1.5.5.7.3.9");
        byte[] request = OcspResponse.BuildRequest(Pki.Leaf, Pki.Intermediate);

        var current = OcspResponse.Parse(new FakeNetwork { Responder = responder }.Post(Pki.OcspUrl, "application/ocsp-request", request)!)!;
        var late = OcspResponse.Parse(new FakeNetwork { Responder = responder, Issued = Pki.NotAfter.AddDays(30) }.Post(Pki.OcspUrl, "application/ocsp-request", request)!)!;

        Assert.Equal(RevocationState.Good, current.About(Pki.Leaf, Pki.Intermediate).State);
        Assert.Equal(RevocationState.NoData, late.About(Pki.Leaf, Pki.Intermediate).State);
    }
}
