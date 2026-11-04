using System.Security.Cryptography;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Files made to make a viewer show something the signer never signed, and what the verifier says of them.</summary>
public class SignatureAttackTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static readonly byte[] Evil = TestPdf.Latin("BT /F1 18 Tf 40 300 Td (Contract page 1: pay 1,000,000) Tj ET");

    private static SignatureReport Check(byte[] file) => SignatureKit.Verify(file)[0];

    private static byte[] CertifiedAtThree() => SignatureChangeTests.Certified(CertificationLevel.Annotate);

    private static string ViewerText(byte[] file) => Encoding.Latin1.GetString(PdfDocument.Open(file).Pages[0].Contents());

    private static void AssertNotAllowed(SignatureReport report, SignatureChangeKind kind)
    {
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(SignatureProblem.ChangedAfterSigning, report.Problems);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == kind);
        Assert.EndsWith("Changed since.", report.Sentence);
    }

    // The second signed contents stream of FormFile, found by what it draws.
    private static PdfStream PageContent(PdfDocument document) => (PdfStream)document.Resolve(document.Pages[0].Dictionary["Contents"])!;

    [Fact]
    public void An_incremental_save_that_rewrites_page_content_is_caught_even_at_the_loosest_level()
    {
        byte[] attacked = SignatureChangeTests.Edit(CertifiedAtThree(), d => PageContent(d).Data = Evil);

        Assert.Contains("pay 1,000,000", ViewerText(attacked));
        AssertNotAllowed(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Fact]
    public void A_shadow_overlay_added_to_the_page_is_caught()
    {
        byte[] attacked = SignatureChangeTests.Edit(CertifiedAtThree(), d =>
        {
            var page = d.Pages[0];
            var overlay = d.Add(new PdfStream(new PdfDictionary(), TestPdf.Latin("q 1 1 1 rg 30 280 240 50 re f Q " + Encoding.Latin1.GetString(Evil))));
            page.Dictionary["Contents"] = new PdfArray([page.Dictionary["Contents"]!, overlay]);
        });

        AssertNotAllowed(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Fact]
    public void An_overlay_stamp_is_only_a_comment_where_comments_are_allowed()
    {
        byte[] covered = SignatureChangeTests.Edit(SignatureChangeTests.Certified(CertificationLevel.FormFill), d =>
            new PdfAnnotationWriter(d).AddStamp(d.Pages[0], new PdfRect(30, 280, 270, 330), "Approved"));

        AssertNotAllowed(Check(covered), SignatureChangeKind.Comment);
    }

    [Fact]
    public void Hidden_content_in_the_signed_file_cannot_be_switched_on_later()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        pdf.Stream(6, "", Encoding.Latin1.GetString(Evil));
        byte[] signed = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate });
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => d.Pages[0].Dictionary["Contents"] = new PdfReference(6, 0));

        Assert.Contains("pay 1,000,000", ViewerText(attacked));
        AssertNotAllowed(Check(attacked), SignatureChangeKind.PageContent);
    }

    [Fact]
    public void An_object_that_a_dangling_reference_of_the_signed_file_starts_to_resolve_to_is_caught()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents [4 0 R 9 0 R]>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        byte[] signed = PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate });
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = SignatureChangeTests.Edit(signed, d => d.Set(9, new PdfStream(new PdfDictionary(), Evil)));

        Assert.Contains("pay 1,000,000", ViewerText(attacked));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Check(attacked).Verdict);
    }

    // A signature that is correct for a byte range of the signer's own choosing: the digest and the CMS are made again.
    private static byte[] Resign(byte[] file, Func<int, int, int, (int GapStart, int GapEnd, int End)> shape)
    {
        var found = SignatureScan.Find(file)[0];
        var numbers = ((PdfArray)found.Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        int a = numbers[1], b = numbers[2], end = b + numbers[3];
        var (gapStart, gapEnd, newEnd) = shape(a, b, end);

        byte[] copy = (byte[])file.Clone();
        int rangeAt = copy.AsSpan().IndexOf(TestPdf.Latin($"[0 {a:D10} {b:D10} {numbers[3]:D10}]"));
        Encoding.ASCII.GetBytes($"[0 {gapStart:D10} {gapEnd:D10} {newEnd - gapEnd:D10}]", copy.AsSpan(rangeAt));
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(copy.AsSpan(0, gapStart));
        hash.AppendData(copy.AsSpan(gapEnd, newEnd - gapEnd));
        var settings = new CmsSettings(Pki.Leaf, Pki.Chain, HashAlgorithmName.SHA256, true, Pki.Signing, null);
        byte[] cms = CmsBuilder.Build(hash.GetHashAndReset(), settings, null);
        Encoding.ASCII.GetBytes(Convert.ToHexString(cms), copy.AsSpan(a + 1));
        return copy;
    }

    [Fact]
    public void A_byte_range_that_stops_short_of_the_revision_is_broken_even_with_a_matching_signature()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        Assert.Equal(SignatureVerdict.Valid, Check(Resign(signed, (a, b, end) => (a, b, end))).Verdict);

        var report = Check(Resign(signed, (a, b, end) => (a, b, end - 40)));

        Assert.Equal(SignatureVerdict.Broken, report.Verdict);
        Assert.Equal([SignatureProblem.BadByteRange], report.Problems);
    }

    [Fact]
    public void A_gap_wider_than_the_contents_is_broken_even_with_a_matching_signature()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));

        Assert.Equal(SignatureVerdict.Broken, Check(Resign(signed, (a, b, end) => (a, b + 12, end))).Verdict);
        Assert.Equal(SignatureVerdict.Broken, Check(Resign(signed, (a, b, end) => (a - 14, b, end))).Verdict);
    }

    [Fact]
    public void A_byte_range_that_leaves_out_objects_before_the_contents_is_broken()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        var found = SignatureScan.Find(signed)[0];
        int a = ((PdfNumber)((PdfArray)found.Dictionary["ByteRange"]!).Items[1]).Integer is { } n ? (int)n : 0;
        var revisions = PdfRevisions.List(signed);

        // The first range must start at 0; a signature over the tail alone says nothing of the start.
        var tail = new PdfDictionary
        {
            ["ByteRange"] = new PdfArray([new PdfNumber(40), new PdfNumber(a), new PdfNumber(a + 10), new PdfNumber(5)]),
            ["Contents"] = found.Dictionary["Contents"]!,
        };
        Assert.Null(SignedRanges.Check(signed, found with { Dictionary = tail }, revisions));
    }

    [Theory]
    [InlineData("[0 10 20]")]
    [InlineData("[0 10 20 30 40 50]")]
    [InlineData("[0 -1 20 30]")]
    [InlineData("[1 10 20 30]")]
    [InlineData("[0 20 10 30]")]
    [InlineData("[0 10 20 99999999]")]
    [InlineData("[0 99999999 99999999 0]")]
    [InlineData("[0.5 10 20 30]")]
    [InlineData("[]")]
    public void Malformed_byte_ranges_are_refused_without_throwing(string text)
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        var found = SignatureScan.Find(signed)[0];
        var forged = new PdfDictionary
        {
            ["ByteRange"] = new PdfLexer(new PdfArrayBytes(TestPdf.Latin(text))).ReadObject(),
            ["Contents"] = found.Dictionary["Contents"]!,
        };

        Assert.Null(SignedRanges.Check(signed, found with { Dictionary = forged }, PdfRevisions.List(signed)));
    }

    [Fact]
    public void A_signature_field_whose_value_is_replaced_after_signing_is_caught()
    {
        byte[] attacked = SignatureChangeTests.Edit(CertifiedAtThree(), d =>
        {
            var field = PdfForm.Read(d).Fields.First(f => f.Kind == FieldKind.Signature);
            var fake = new PdfDictionary { ["Type"] = new PdfName("Sig"), ["Filter"] = new PdfName("Adobe.PPKLite") };
            field.Dictionary["V"] = d.Add(fake);
        });

        var report = Check(attacked);

        AssertNotAllowed(report, SignatureChangeKind.Signature);
        Assert.Equal("Signature1", report.Changes.NotAllowed.First(c => c.Kind == SignatureChangeKind.Signature).Field);
    }

    [Fact]
    public void A_signature_field_that_is_taken_out_of_the_form_is_caught()
    {
        byte[] attacked = SignatureChangeTests.Edit(CertifiedAtThree(), d =>
        {
            var field = PdfForm.Read(d).Fields.First(f => f.Kind == FieldKind.Signature);
            d.Array(d.Dict(d.Catalog, "AcroForm"), "Fields")!.Items.RemoveAll(i => i is PdfReference r && r.Number == field.Reference!.Number);
            d.Array(d.Pages[0].Dictionary, "Annots")!.Items.RemoveAll(i => i is PdfReference r && r.Number == field.Reference!.Number);
        });

        var report = Check(attacked);

        AssertNotAllowed(report, SignatureChangeKind.Form);
        Assert.Null(report.FieldName);
    }

    [Fact]
    public void A_signature_the_attacker_makes_over_the_changed_file_does_not_vouch_for_the_signer()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);
        byte[] changed = SignatureChangeTests.Edit(signed, d => PageContent(d).Data = Evil);
        byte[] resigned = PdfSigner.Sign(changed, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain });

        var reports = SignatureKit.Verify(resigned);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, reports[0].Verdict);
        Assert.Equal("Ada Lovelace", reports[0].SignerName);
        Assert.Equal(SignatureVerdict.Valid, reports[1].Verdict);
        Assert.Equal("Grace Hopper", reports[1].SignerName);
    }

    // A signed file whose page content exists twice: the table names the good copy, a second definition sits unused in the signed part.
    private static (byte[] Signed, long EvilOffset) FileWithHiddenCopy()
    {
        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400]>>");
        pdf.Obj(3, "<</Type /Page /Parent 2 0 R /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R>>");
        pdf.Stream(4, "", "BT /F1 18 Tf 40 300 Td (Contract page 1) Tj ET");
        pdf.Obj(5, "<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>");
        long evil = pdf.Position;
        string body = Encoding.Latin1.GetString(Evil);
        pdf.Write($"4 0 obj\n<</Length {body.Length}>>\nstream\n{body}\nendstream\nendobj\n");
        return (PdfSigner.Sign(pdf.Finish(), SignatureKit.Request(Pki) with { Certify = CertificationLevel.Annotate }), evil);
    }

    private static byte[] AppendSection(byte[] signed, string objects, string entries, bool pointAtOld)
    {
        var document = PdfDocument.Open(signed);
        long prev = document.StartXref;
        var sb = new StringBuilder("\n" + objects);
        long xref = signed.Length + sb.Length;
        sb.Append($"xref\n{entries}trailer\n<</Size {document.NextObjectNumber} /Root 1 0 R /Prev {prev}>>\nstartxref\n{(pointAtOld ? prev : xref)}\n%%EOF\n");
        return [.. signed, .. TestPdf.Latin(sb.ToString())];
    }

    [Fact]
    public void An_update_that_only_points_the_table_at_a_hidden_definition_is_caught()
    {
        var (signed, evil) = FileWithHiddenCopy();
        Assert.Equal(SignatureVerdict.Valid, Check(signed).Verdict);

        byte[] attacked = AppendSection(signed, "", $"4 1\n{evil:D10} 00000 n \n", pointAtOld: false);

        Assert.Contains("pay 1,000,000", ViewerText(attacked));
        Assert.Empty(PdfDocument.Open(attacked).Repairs);
        var report = Check(attacked);
        AssertNotAllowed(report, SignatureChangeKind.PageContent);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == 4);
    }

    [Fact]
    public void A_broken_table_that_sends_a_repairing_viewer_to_the_newest_copy_is_caught()
    {
        var (signed, _) = FileWithHiddenCopy();
        string body = Encoding.Latin1.GetString(Evil);
        byte[] attacked = [.. signed, .. TestPdf.Latin($"\n4 0 obj\n<</Length {body.Length}>>\nstream\n{body}\nendstream\nendobj\nstartxref\n99999999\n%%EOF\n")];

        Assert.True(PdfDocument.Open(attacked).XrefRebuilt);
        Assert.Contains("pay 1,000,000", ViewerText(attacked));
        AssertNotAllowed(Check(attacked), SignatureChangeKind.Other);
    }

    [Fact]
    public void A_copy_slipped_in_after_the_signature_that_a_scanning_viewer_would_pick_up_is_caught()
    {
        var (signed, _) = FileWithHiddenCopy();
        string body = Encoding.Latin1.GetString(Evil);
        string copy = $"4 0 obj\n<</Length {body.Length}>>\nstream\n{body}\nendstream\nendobj\n";

        // The final table still names the signed objects, so a table-following viewer shows the signed page.
        byte[] attacked = AppendSection(signed, copy, "", pointAtOld: true);

        Assert.DoesNotContain("pay 1,000,000", ViewerText(attacked));
        var report = Check(attacked);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Object == 4);
    }

    [Fact]
    public void A_later_definition_that_an_update_lists_is_not_taken_for_a_trick()
    {
        // The same shape in an honest file: an update that rewrites the stream and lists it.
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);
        byte[] twice = SignatureChangeTests.Edit(SignatureChangeTests.Edit(signed, d => new PdfAnnotationWriter(d).AddNote(d.Pages[0], new PdfRect(250, 350, 270, 370), new AnnotationInfo("A", "one"))),
            d => new PdfAnnotationWriter(d).AddNote(d.Pages[0], new PdfRect(250, 320, 270, 340), new AnnotationInfo("A", "two")));

        Assert.Equal(SignatureVerdict.Valid, Check(twice).Verdict);
    }

    [Fact]
    public void A_stream_that_contains_a_pdf_does_not_look_like_a_hidden_object()
    {
        byte[] signed = SignatureChangeTests.Certified(CertificationLevel.Annotate);
        byte[] inner = PdfDocument.Open(SignatureKit.Plain()).SaveIncremental();
        byte[] attached = SignatureChangeTests.Edit(signed, d => d.Add(new PdfStream(new PdfDictionary(), inner)));

        Assert.Equal(SignatureVerdict.Valid, Check(attached).Verdict);
    }

    [Fact]
    public void Damaged_files_never_crash_the_verifier()
    {
        var network = new FakeNetwork();
        byte[] original = PdfSigner.Sign(ChangeDetectionTestsFile(), SignatureKit.Request(Pki) with { Timestamp = new TimestampSettings(network, "http://tsa.test/"), Level = PadesLevel.LTA });
        var random = new Random(11);
        int refused = 0;
        for (int round = 0; round < 300; round++)
        {
            byte[] copy = (byte[])original.Clone();
            int hits = random.Next(1, 6);
            for (int k = 0; k < hits; k++) copy[random.Next(copy.Length)] = (byte)random.Next(256);
            if (round % 10 == 0) copy = copy.AsSpan(0, random.Next(copy.Length)).ToArray();
            try
            {
                foreach (var report in SignatureKit.Verify(copy)) _ = report.Sentence;
            }
            catch (PdfReadException)
            {
                refused++;
            }
        }
        Assert.True(refused < 300);
    }

    private static byte[] ChangeDetectionTestsFile() => SignatureChangeTests.FormFile();
}
