using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

/// <summary>Files and certificates built to pass for something they are not, and files that are sound but unusual.</summary>
public class SignatureHardeningTests
{
    private static readonly Pki Pki = Pki.Instance;
    private const string StampUrl = "http://tsa.test/";
    private const string TimeStamping = "1.3.6.1.5.5.7.3.8";
    private const string EmailProtection = "1.3.6.1.5.5.7.3.4";
    private const string OcspSigning = "1.3.6.1.5.5.7.3.9";

    private static SignatureReport One(byte[] file) => Assert.Single(SignatureKit.Verify(file));

    private static PdfSignRequest By(X509Certificate2 certificate) => new(certificate, Pki.Signing) { Chain = Pki.Chain };

    private static PdfSignRequest Archived(FakeNetwork network) =>
        SignatureKit.Request(Pki) with { Timestamp = new TimestampSettings(network, StampUrl), Level = PadesLevel.LT };

    private static SignatureReport CheckFirst(byte[] file) => SignatureKit.Verify(file)[0];

    // ---- changes after signing

    private static byte[] Retitled(byte[] file, int count)
    {
        for (int i = 0; i < count; i++)
        {
            int title = i;
            file = SignatureChangeTests.Edit(file, d => (DocumentMetadata.Read(d) with { Title = $"Title {title}" }).Write(d));
        }
        return file;
    }

    // An object the update does not list but a scanning viewer would find, closed by a tail that points at the old table.
    private static byte[] WithUnlistedCopy(byte[] file, string lead)
    {
        var document = PdfDocument.Open(file);
        int contents = ((PdfReference)document.Pages[0].Dictionary["Contents"]!).Number;
        const string Body = "BT /F1 18 Tf 40 300 Td (pay 1,000,000) Tj ET";
        string tail = $"\n{lead}{contents} 0 obj\n<</Length {Body.Length}>>\nstream\n{Body}\nendstream\nendobj\nxref\ntrailer\n<</Size {document.NextObjectNumber} /Root 1 0 R /Prev {document.StartXref}>>\nstartxref\n{document.StartXref}\n%%EOF\n";
        return [.. file, .. TestPdf.Latin(tail)];
    }

    [Fact]
    public void An_unlisted_object_in_the_middle_of_a_line_is_found_like_one_at_its_start()
    {
        byte[] certified = SignatureChangeTests.Certified(CertificationLevel.Annotate);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, CheckFirst(WithUnlistedCopy(certified, "% ")).Verdict);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, CheckFirst(WithUnlistedCopy(certified, "")).Verdict);
        Assert.Equal(SignatureVerdict.Valid, CheckFirst(Retitled(certified, 1)).Verdict);
    }

    [Fact]
    public void Many_later_revisions_do_not_switch_the_unlisted_object_check_off()
    {
        byte[] many = Retitled(SignatureChangeTests.Certified(CertificationLevel.Annotate), 20);

        Assert.Equal(SignatureVerdict.Valid, CheckFirst(many).Verdict);
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, CheckFirst(WithUnlistedCopy(many, "")).Verdict);
    }

    [Fact]
    public void Revisions_that_cannot_all_be_opened_leave_the_file_unchecked_and_so_changed()
    {
        byte[] flooded = Retitled(SignatureChangeTests.Certified(CertificationLevel.Annotate), 70);

        var report = CheckFirst(flooded);

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, report.Verdict);
        Assert.Contains(report.Changes.NotAllowed, c => c.Kind == SignatureChangeKind.Other);
    }

    [Fact]
    public void A_signature_that_runs_to_the_end_of_a_file_with_blank_bytes_after_the_marker_is_valid()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        foreach (string blank in new[] { " \n", "\n\n", "\r\n\r\n", " \n \n" })
        {
            byte[] padded = [.. signed, .. TestPdf.Latin(blank)];

            var report = One(SignatureAttackTests.Resign(padded, (a, b, end) => (a, b, end + blank.Length)));

            Assert.Equal(SignatureVerdict.Valid, report.Verdict);
            Assert.True(report.CoversWholeFile);
        }
    }

    [Fact]
    public void Blank_bytes_are_all_a_range_may_run_past_the_revision()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        byte[] padded = [.. signed, .. TestPdf.Latin("\n\n12 0 obj\n<<>>\nendobj\n")];

        var report = One(SignatureAttackTests.Resign(padded, (a, b, end) => (a, b, padded.Length)));

        Assert.Equal(SignatureVerdict.Broken, report.Verdict);
    }

    // ---- what makes a signature

    [Fact]
    public void Malformed_PSS_parameters_break_that_signature_and_nothing_else()
    {
        byte[] file = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Format = SignatureFormat.Pkcs7Detached });
        byte[] forged = SignatureKit.Splice(file, content =>
        {
            byte[] cms = SignatureVerificationTests.ByFramework(content, Pki.Leaf, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
            // The salt length, an INTEGER in a [2], becomes an OCTET STRING.
            int at = cms.AsSpan().IndexOf(new byte[] { 0xA2, 0x03, 0x02, 0x01, 0x20 });
            Assert.True(at > 0);
            cms[at + 2] = 0x04;
            return cms;
        });
        byte[] second = PdfSigner.Sign(forged, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, FieldName = "Second" });

        var reports = SignatureKit.Verify(second);

        Assert.Equal(SignatureVerdict.Broken, reports[0].Verdict);
        Assert.Equal(SignatureVerdict.Valid, reports[1].Verdict);
    }

    [Fact]
    public void A_certificate_made_for_web_servers_is_not_a_document_signer()
    {
        using var server = Pki.Issued("Web Server", X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, "1.3.6.1.5.5.7.3.1");

        var report = One(PdfSigner.Sign(SignatureKit.Plain(), By(server)));

        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.Contains(SignatureProblem.UntrustedSigner, report.Problems);
    }

    [Fact]
    public void A_certificate_that_may_only_sign_certificates_is_not_a_document_signer()
    {
        using var authority = Pki.Issued("Key Signer", X509KeyUsageFlags.KeyCertSign);

        var report = One(PdfSigner.Sign(SignatureKit.Plain(), By(authority)));

        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.Contains(SignatureProblem.UntrustedSigner, report.Problems);
    }

    [Fact]
    public void A_mail_certificate_signs_documents()
    {
        using var mail = Pki.Issued("Mail", X509KeyUsageFlags.DigitalSignature, EmailProtection);

        Assert.Equal(SignatureVerdict.Valid, One(PdfSigner.Sign(SignatureKit.Plain(), By(mail))).Verdict);
    }

    [Fact]
    public void A_time_stamp_authority_needs_the_time_stamping_purpose()
    {
        using var plain = Pki.Issued("Plain", X509KeyUsageFlags.DigitalSignature);
        using var mail = Pki.Issued("Mail", X509KeyUsageFlags.DigitalSignature, EmailProtection);
        using var both = Pki.Issued("Both", X509KeyUsageFlags.DigitalSignature, EmailProtection, TimeStamping);

        bool Trusted(X509Certificate2 certificate, bool stamp) =>
            CertificateTrust.Evaluate(certificate, Pki.Chain, Pki.Signing, Pki.Trusting, timestamp: stamp).Trusted;

        Assert.False(Trusted(plain, true));
        Assert.False(Trusted(mail, true));
        Assert.True(Trusted(both, true));
        Assert.True(Trusted(Pki.Tsa, true));
        Assert.False(Trusted(Pki.Tsa, false));
    }

    [Fact]
    public void A_time_stamp_from_an_authority_nobody_trusts_does_not_move_the_signing_time()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Own Stamps", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid(TimeStamping)], true));
        using var own = request.CreateSelfSigned(Pki.NotBefore, Pki.NotAfter);
        var network = new FakeNetwork { StampCertificate = own, StampTime = Pki.Signing.AddYears(-1) };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Timestamp = new TimestampSettings(network, StampUrl), Level = PadesLevel.T });
        var options = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Signing.AddDays(5) };

        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, options));

        Assert.Null(report.TimestampTime);
        Assert.Equal(options.Now, report.TimeUsed);
    }

    [Fact]
    public void A_revocation_after_the_claimed_time_counts_when_nothing_proves_the_time()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        byte[] archived = PdfLongTermValidation.Add(signed, new FakeNetwork { Revoked = true, RevokedAt = Pki.Signing.AddDays(30) }, Pki.Signing);
        var later = new VerifyOptions { TrustAnchors = [Pki.Root], Now = Pki.Signing.AddDays(60) };

        var report = Assert.Single(PdfSignatureVerifier.Verify(archived, later));

        Assert.Contains(SignatureProblem.CertificateRevoked, report.Problems);
        Assert.NotEqual(SignatureVerdict.Valid, report.Verdict);
    }

    // ---- revocation data

    private static byte[] AnswerOf(FakeNetwork network) =>
        network.Post(Pki.OcspUrl, "application/ocsp-request", OcspResponse.BuildRequest(Pki.Leaf, Pki.Intermediate))!;

    [Fact]
    public void An_ocsp_answer_signed_by_a_certificate_without_the_ocsp_purpose_says_nothing()
    {
        using var colleague = Pki.Issued("Colleague", X509KeyUsageFlags.DigitalSignature);
        using var responder = Pki.Issued("Responder", X509KeyUsageFlags.DigitalSignature, OcspSigning);

        foreach (bool revoked in new[] { false, true })
        {
            Assert.Equal(RevocationState.NoData, OcspResponse.Parse(AnswerOf(new FakeNetwork { Responder = colleague, Revoked = revoked }))!.About(Pki.Leaf, Pki.Intermediate).State);
        }
        Assert.Equal(RevocationState.Good, OcspResponse.Parse(AnswerOf(new FakeNetwork { Responder = responder }))!.About(Pki.Leaf, Pki.Intermediate).State);
        Assert.Equal(RevocationState.Revoked, OcspResponse.Parse(AnswerOf(new FakeNetwork { Responder = responder, Revoked = true }))!.About(Pki.Leaf, Pki.Intermediate).State);
    }

    [Fact]
    public void Archived_revocation_data_from_a_lesser_responder_does_not_lift_the_level()
    {
        using var colleague = Pki.Issued("Colleague", X509KeyUsageFlags.DigitalSignature);
        using var responder = Pki.Issued("Responder", X509KeyUsageFlags.DigitalSignature, OcspSigning);

        var forged = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(new FakeNetwork { Responder = colleague, CrlDown = true })));
        var proper = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(new FakeNetwork { Responder = responder, CrlDown = true })));

        Assert.False(forged.RevocationChecked);
        Assert.Equal(PadesLevel.T, forged.Level);
        Assert.True(proper.RevocationChecked);
        Assert.Equal(PadesLevel.LT, proper.Level);
    }

    [Fact]
    public void An_answer_older_than_the_time_stamp_proves_nothing_unless_it_is_still_valid_then()
    {
        var old = Pki.Signing.AddDays(-30);

        var stale = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(new FakeNetwork { Issued = old, CrlDown = true })));
        var covering = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(new FakeNetwork { Issued = old, NextUpdate = Pki.Signing.AddDays(5), CrlDown = true })));
        var fresh = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(new FakeNetwork { CrlDown = true })));

        Assert.False(stale.RevocationChecked);
        Assert.True(covering.RevocationChecked);
        Assert.True(fresh.RevocationChecked);
    }

    [Fact]
    public void A_list_that_ran_out_before_the_time_stamp_proves_nothing()
    {
        var old = Pki.Signing.AddDays(-30);

        var stale = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(new FakeNetwork { OcspDown = true, Issued = old, NextUpdate = Pki.Signing.AddDays(-20) })));
        var covering = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(new FakeNetwork { OcspDown = true, Issued = old, NextUpdate = Pki.Signing.AddDays(20) })));

        Assert.False(stale.RevocationChecked);
        Assert.True(covering.RevocationChecked);
    }

    private static X509Extension Scope(int tag)
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence()) w.WriteBoolean(true, new Asn1Tag(TagClass.ContextSpecific, tag));
        return new X509Extension("2.5.29.28", w.Encode(), true);
    }

    private static X509Extension Delta()
    {
        var w = new AsnWriter(AsnEncodingRules.DER);
        w.WriteInteger(1);
        return new X509Extension("2.5.29.27", w.Encode(), true);
    }

    [Theory]
    [InlineData("authorities")]
    [InlineData("attributes")]
    [InlineData("delta")]
    [InlineData("whole")]
    public void A_list_that_does_not_cover_the_certificate_does_not_make_it_good(string kind)
    {
        X509Extension? extension = kind switch { "authorities" => Scope(2), "attributes" => Scope(5), "delta" => Delta(), _ => null };
        var network = new FakeNetwork { OcspDown = true, CrlExtension = extension };

        var report = One(PdfSigner.Sign(SignatureKit.Plain(), Archived(network)));

        Assert.Equal(kind == "whole", report.RevocationChecked);
        Assert.Equal(kind == "whole" ? PadesLevel.LT : PadesLevel.T, report.Level);
    }

    [Fact]
    public void A_list_for_end_entities_only_covers_the_signer()
    {
        var network = new FakeNetwork { OcspDown = true, CrlExtension = Scope(1) };

        Assert.True(One(PdfSigner.Sign(SignatureKit.Plain(), Archived(network))).RevocationChecked);
    }

    // ---- signing into a file with rules

    [Fact]
    public void A_document_time_stamp_and_validation_data_still_follow_a_certification_without_changes()
    {
        var network = new FakeNetwork();
        byte[] certified = SignatureChangeTests.Certified(CertificationLevel.NoChanges);

        byte[] stamped = PdfSigner.AddDocumentTimestamp(certified, new TimestampSettings(network, StampUrl), Pki.Signing.AddDays(1));
        byte[] archived = PdfLongTermValidation.Add(stamped, network, Pki.Signing.AddDays(1));

        Assert.All(SignatureKit.Verify(archived), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
    }

    [Fact]
    public void A_field_an_earlier_signature_locked_is_not_signed()
    {
        var empty = PdfDocument.Open(SignatureKit.Plain());
        PdfForm.Read(empty).AddField(new FieldSpec(FieldKind.Signature, "Later", 0, new PdfRect(10, 10, 100, 40)));
        byte[] prepared = empty.SaveIncremental();
        byte[] locked = PdfSigner.Sign(prepared, SignatureKit.Request(Pki) with { Lock = new FieldLock(FieldLockAction.Include, ["Later"]) });
        byte[] open = PdfSigner.Sign(prepared, SignatureKit.Request(Pki) with { Lock = new FieldLock(FieldLockAction.Include, ["Other"]) });

        var thrown = Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(locked, By(Pki.LeafEc) with { FieldName = "Later" }));

        Assert.Equal(SignatureText.FieldLocked, thrown.Message);
        Assert.All(SignatureKit.Verify(PdfSigner.Sign(open, By(Pki.LeafEc) with { FieldName = "Later" })), r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
    }

    // ---- digital ids

    [Fact]
    public void An_imported_id_keeps_its_key_in_memory_and_the_file_is_protected_with_AES()
    {
        using var id = PdfDigitalId.Create("Ada Lovelace", null, new DateTimeOffset(2026, 3, 1, 0, 0, 0, TimeSpan.Zero), keyBits: 2048);

        byte[] pfx = PdfDigitalId.ExportPfx(id, "pass word");
        using var loaded = PdfDigitalId.ImportPfx(pfx, "pass word");

        string hex = Convert.ToHexString(pfx);
        Assert.Contains("2A864886F70D01050D", hex);
        Assert.DoesNotContain("2A864886F70D010C0103", hex);
        using var key = loaded.GetRSAPrivateKey()!;
        if (key is RSACng cng) Assert.True(cng.Key.IsEphemeral);
        Assert.Equal(SignatureVerdict.ValidButUntrusted, One(PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(loaded, Pki.Signing))).Verdict);
    }

    // ---- appearance

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void The_appearance_of_a_visible_signature_stands_upright_on_a_turned_page(int rotate)
    {
        var document = PdfDocument.Open(SignatureKit.Plain());
        document.Pages[0].Dictionary["Rotate"] = new PdfNumber(rotate);
        byte[] turned = document.SaveIncremental();
        var rect = new PdfRect(20, 20, 200, 60);

        byte[] signed = PdfSigner.Sign(turned, SignatureKit.Request(Pki) with { Rect = rect });

        var reopened = PdfDocument.Open(signed);
        var form = (PdfStream)reopened.Resolve(reopened.Dict(PdfForm.Read(reopened).Fields.First(f => f.Kind == FieldKind.Signature).Widgets[0].Dictionary, "AP")!["N"])!;
        double[] box = [.. reopened.Array(form.Dictionary, "BBox")!.Items.Select(i => ((PdfNumber)i).Value)];
        double[] m = [.. reopened.Array(form.Dictionary, "Matrix")!.Items.Select(i => ((PdfNumber)i).Value)];
        bool sideways = rotate is 90 or 270;
        Assert.Equal(sideways ? rect.Height : rect.Width, box[2]);
        Assert.Equal(sideways ? rect.Width : rect.Height, box[3]);

        // The form's right-pointing axis, turned the way the page is turned, points right again.
        (double x, double y) = (m[0], m[1]);
        for (int i = 0; i < rotate / 90; i++) (x, y) = (y, -x);
        Assert.Equal((1, 0), (Math.Round(x), Math.Round(y)));
        Assert.Equal(rect.Width, Math.Abs(m[0] * box[2] + m[2] * box[3]));
        Assert.Equal(rect.Height, Math.Abs(m[1] * box[2] + m[3] * box[3]));
        Assert.Equal(SignatureVerdict.Valid, One(signed).Verdict);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(signed);
        Assert.Equal(2, pig.NumberOfPages);
    }
}
