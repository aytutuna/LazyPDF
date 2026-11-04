using System.Formats.Asn1;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureVerificationTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static byte[] Signed(Func<PdfSignRequest, PdfSignRequest>? change = null)
    {
        var request = SignatureKit.Request(Pki);
        return PdfSigner.Sign(SignatureKit.Plain(), change is null ? request : change(request));
    }

    [Fact]
    public void Without_trust_anchors_the_signer_is_valid_but_not_trusted()
    {
        var report = Assert.Single(PdfSignatureVerifier.Verify(Signed()));

        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.Contains(SignatureProblem.UntrustedSigner, report.Problems);
        Assert.Equal("Ada Lovelace", report.SignerName);
    }

    [Fact]
    public void A_self_signed_certificate_is_trusted_only_when_the_caller_says_so()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(Pki.SelfSigned, Pki.Signing));

        Assert.Equal(SignatureVerdict.ValidButUntrusted, Assert.Single(PdfSignatureVerifier.Verify(signed, Pki.Trusting)).Verdict);
        var pinned = new VerifyOptions { TrustAnchors = [Pki.SelfSigned] };
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(PdfSignatureVerifier.Verify(signed, pinned)).Verdict);
    }

    [Theory]
    [InlineData(2024)]
    [InlineData(2041)]
    public void A_certificate_outside_its_validity_at_signing_time_is_not_trusted(int year)
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Time = new DateTimeOffset(year, 6, 1, 0, 0, 0, TimeSpan.Zero) });

        var report = Assert.Single(SignatureKit.Verify(signed));
        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.Contains(SignatureProblem.CertificateNotValid, report.Problems);
        Assert.DoesNotContain(SignatureProblem.UntrustedSigner, report.Problems);
    }

    [Fact]
    public void A_changed_byte_in_the_signed_range_breaks_the_digest()
    {
        byte[] signed = Signed();
        byte[] tampered = TestPdf.Replace(signed, "Contract page 1", "Contract page 9");

        var report = Assert.Single(SignatureKit.Verify(tampered));
        Assert.Equal(SignatureVerdict.Broken, report.Verdict);
        Assert.Equal([SignatureProblem.DigestMismatch], report.Problems);
        Assert.Equal("The signature by Ada Lovelace is not valid.", report.Sentence);
    }

    [Fact]
    public void A_changed_signature_value_is_a_bad_signature()
    {
        byte[] signed = Signed();
        var found = SignatureScan.Find(signed)[0];
        int length = CmsSignature.Parse(((PdfString)found.Dictionary["Contents"]!).Bytes)!.Length;
        var range = ((PdfArray)found.Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        int lastHexDigit = range[1] + 1 + 2 * length - 1;
        signed[lastHexDigit] = signed[lastHexDigit] == (byte)'0' ? (byte)'1' : (byte)'0';

        var report = Assert.Single(SignatureKit.Verify(signed));

        Assert.Equal(SignatureVerdict.Broken, report.Verdict);
        Assert.Contains(report.Problems, p => p is SignatureProblem.BadSignature or SignatureProblem.BadByteRange);
    }

    [Fact]
    public void Data_after_the_signature_inside_contents_is_refused()
    {
        byte[] signed = Signed();
        var range = ((PdfArray)SignatureScan.Find(signed)[0].Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        signed[range[2] - 2] = (byte)'1';

        Assert.Equal(SignatureVerdict.Broken, Assert.Single(SignatureKit.Verify(signed)).Verdict);
    }

    [Fact]
    public void A_signature_format_we_do_not_read_is_unknown_not_valid()
    {
        byte[] signed = TestPdf.Replace(Signed(), "/ETSI.CAdES.detached", "/ETSI.CAdES.detachee");

        var report = Assert.Single(SignatureKit.Verify(signed));

        Assert.Equal(SignatureVerdict.Unknown, report.Verdict);
        Assert.Equal([SignatureProblem.UnsupportedFormat], report.Problems);
    }

    [Fact]
    public void An_unsigned_file_has_no_reports_and_junk_does_not_look_like_a_signature()
    {
        Assert.Empty(SignatureKit.Verify(SignatureKit.Plain()));

        var pdf = new TestPdf();
        pdf.Obj(1, "<</Type /Catalog /Pages 2 0 R>>");
        pdf.Obj(2, "<</Type /Pages /Kids [] /Count 0>>");
        pdf.Stream(3, "", "text with /ByteRange [0 1 2 3] and /Contents <00> inside a stream");
        Assert.Empty(SignatureKit.Verify(pdf.Finish()));
    }

    [Fact]
    public void An_embedded_time_stamp_fixes_the_signing_time_and_raises_the_level()
    {
        var network = new FakeNetwork { StampTime = Pki.Signing.AddHours(2) };
        byte[] signed = Signed(r => r with { Timestamp = new TimestampSettings(network, "http://tsa.test/") });

        var report = Assert.Single(SignatureKit.Verify(signed));

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal(PadesLevel.T, report.Level);
        Assert.Equal(Pki.Signing.AddHours(2), report.TimestampTime);
        Assert.Equal(report.TimestampTime, report.TimeUsed);
        Assert.Equal(["http://tsa.test/"], network.Requests);
    }

    [Fact]
    public void A_certificate_that_expired_before_the_time_stamp_is_not_valid_at_that_time()
    {
        var network = new FakeNetwork { StampTime = Pki.Expiry.AddMonths(3) };
        var request = new PdfSignRequest(Pki.ShortLived, Pki.Signing) { Chain = Pki.Chain, Timestamp = new TimestampSettings(network, "http://tsa.test/") };

        var report = Assert.Single(SignatureKit.Verify(PdfSigner.Sign(SignatureKit.Plain(), request)));

        Assert.Contains(SignatureProblem.CertificateNotValid, report.Problems);
        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
    }

    [Fact]
    public void A_certificate_that_has_expired_since_is_still_good_for_a_time_stamped_signature()
    {
        var network = new FakeNetwork { StampTime = Pki.Signing.AddMinutes(1) };
        var request = new PdfSignRequest(Pki.ShortLived, Pki.Signing) { Chain = Pki.Chain, Timestamp = new TimestampSettings(network, "http://tsa.test/") };

        var report = Assert.Single(SignatureKit.Verify(PdfSigner.Sign(SignatureKit.Plain(), request)));

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.True(Pki.ShortLived.NotAfter < DateTime.Now, "The test needs the certificate to have expired by the clock.");
    }

    [Fact]
    public void A_damaged_time_stamp_is_reported_and_the_claimed_time_is_used()
    {
        var network = new FakeNetwork();
        byte[] signed = Signed(r => r with { Timestamp = new TimestampSettings(network, "http://tsa.test/") });
        // The token's own signature sits near the end of the CMS, before the zero padding.
        var found = SignatureScan.Find(signed)[0];
        var cms = CmsSignature.Parse(((PdfString)found.Dictionary["Contents"]!).Bytes)!;
        var range = ((PdfArray)found.Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        int at = range[1] + 1 + 2 * (cms.Length - 8);
        signed[at] = signed[at] == (byte)'A' ? (byte)'B' : (byte)'A';

        var report = Assert.Single(SignatureKit.Verify(signed));

        Assert.Contains(SignatureProblem.TimestampInvalid, report.Problems);
        Assert.Null(report.TimestampTime);
        Assert.NotEqual(SignatureVerdict.Valid, report.Verdict);
    }

    [Fact]
    public void A_time_stamp_server_that_fails_stops_the_signature()
    {
        var network = new FakeNetwork { StampDown = true };
        var e = Assert.Throws<InvalidOperationException>(() => Signed(r => r with { Timestamp = new TimestampSettings(network, "http://tsa.test/") }));
        Assert.Equal(SignatureText.NoTimestamp, e.Message);
        Assert.Throws<InvalidOperationException>(() => Signed(r => r with { Timestamp = new TimestampSettings(network) }));
        Assert.Throws<InvalidOperationException>(() => Signed(r => r with { Level = PadesLevel.T }));
    }

    [Fact]
    public void Signed_data_that_is_not_a_signature_never_throws()
    {
        byte[] signed = Signed();
        var random = new Random(5);
        var found = SignatureScan.Find(signed)[0];
        var range = ((PdfArray)found.Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        for (int round = 0; round < 40; round++)
        {
            byte[] copy = (byte[])signed.Clone();
            for (int k = 0; k < 6; k++)
            {
                int at = range[1] + 1 + random.Next(0, range[2] - range[1] - 2);
                copy[at] = (byte)"0123456789ABCDEF"[random.Next(16)];
            }
            var report = Assert.Single(SignatureKit.Verify(copy));
            Assert.NotEqual(SignatureVerdict.Valid, report.Verdict);
        }
    }

    private static byte[] ByFramework(byte[] content, X509Certificate2 certificate, HashAlgorithmName digest, RSASignaturePadding? padding = null, bool attributes = true)
    {
        var cms = new SignedCms(new ContentInfo(content), detached: true);
        var signer = padding is null
            ? new CmsSigner(SubjectIdentifierType.IssuerAndSerialNumber, certificate) { DigestAlgorithm = new Oid(digest.Name == "SHA1" ? "1.3.14.3.2.26" : "2.16.840.1.101.3.4.2.1") }
            : new CmsSigner(SubjectIdentifierType.IssuerAndSerialNumber, certificate, certificate.GetRSAPrivateKey(), padding) { DigestAlgorithm = new Oid("2.16.840.1.101.3.4.2.1") };
        signer.IncludeOption = X509IncludeOption.EndCertOnly;
        if (attributes) signer.SignedAttributes.Add(new Pkcs9SigningTime(Pki.Signing.UtcDateTime));
        foreach (var c in Pki.Chain) signer.Certificates.Add(c);
        cms.ComputeSignature(signer);
        return cms.Encode();
    }

    [Theory]
    [InlineData("pkcs1", true)]
    [InlineData("pss", true)]
    [InlineData("ecdsa", true)]
    [InlineData("pkcs1", false)]
    [InlineData("ecdsa", false)]
    public void A_signature_made_by_the_framework_verifies(string kind, bool attributes)
    {
        byte[] file = Signed(r => r with { Format = SignatureFormat.Pkcs7Detached });
        var certificate = kind == "ecdsa" ? Pki.LeafEc : Pki.Leaf;

        byte[] other = SignatureKit.Splice(file, content => ByFramework(content, certificate, HashAlgorithmName.SHA256, kind == "pss" ? RSASignaturePadding.Pss : null, attributes));

        var report = Assert.Single(SignatureKit.Verify(other));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal(kind == "ecdsa" ? "Grace Hopper" : "Ada Lovelace", report.SignerName);
        Assert.Equal(Pki.Signing, report.SigningTime);
    }

    [Fact]
    public void A_sha1_signature_reads_but_is_called_weak()
    {
        byte[] file = Signed(r => r with { Format = SignatureFormat.Pkcs7Detached });

        byte[] other = SignatureKit.Splice(file, content => ByFramework(content, Pki.Leaf, HashAlgorithmName.SHA1));

        var report = Assert.Single(SignatureKit.Verify(other));
        Assert.Contains(SignatureProblem.WeakDigest, report.Problems);
        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
    }

    [Fact]
    public void A_signature_over_other_bytes_does_not_verify_whoever_made_it()
    {
        byte[] file = Signed(r => r with { Format = SignatureFormat.Pkcs7Detached });

        byte[] other = SignatureKit.Splice(file, content => ByFramework([.. content, 1], Pki.Leaf, HashAlgorithmName.SHA256));

        Assert.Equal([SignatureProblem.DigestMismatch], Assert.Single(SignatureKit.Verify(other)).Problems);
    }

    [Fact]
    public void A_signature_that_names_another_certificate_than_the_one_it_was_made_with_is_broken()
    {
        byte[] file = Signed();
        byte[] Sign(X509Certificate2 named, byte[] content) =>
            CmsBuilder.Build(SHA256.HashData(content),
                new CmsSettings(named, Pki.Chain, HashAlgorithmName.SHA256, true, Pki.Signing, (hash, _) => Pki.LeafEc.GetECDsaPrivateKey()!.SignHash(hash)), null);

        // Signed with Grace's key under Grace's name, and under Ada's: only the first is what it says.
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(SignatureKit.Splice(file, c => Sign(Pki.LeafEc, c)))).Verdict);
        Assert.Equal(SignatureVerdict.Broken, Assert.Single(SignatureKit.Verify(SignatureKit.Splice(file, c => Sign(Pki.Leaf, c)))).Verdict);
    }

    [Fact]
    public void Revocation_data_a_signature_archived_in_itself_is_read()
    {
        var network = new FakeNetwork();
        byte[] answer = network.Post(Pki.OcspUrl, "application/ocsp-request", OcspResponse.BuildRequest(Pki.Leaf, Pki.Intermediate))!;
        byte[] crl = network.Get(Pki.CrlUrl)!;
        var archival = new AsnWriter(AsnEncodingRules.DER);
        using (archival.PushSequence())
        {
            using (archival.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0)))
            using (archival.PushSequence()) archival.WriteEncodedValue(crl);
            using (archival.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 1)))
            using (archival.PushSequence()) archival.WriteEncodedValue(answer);
        }
        var cms = CmsSignature.Parse(SignatureKit.Parts(Signed()).Cms)!;
        cms.Attributes[Oids.RevocationArchival] = [archival.Encode()];

        var data = new ValidationData();
        data.ReadArchival(cms);

        Assert.Single(data.Ocsps);
        Assert.Single(data.Crls);
        Assert.Equal(RevocationState.Good, data.Check(Pki.Leaf, Pki.Intermediate).State);
        Assert.Equal(RevocationState.NoData, data.Check(Pki.Intermediate, Pki.Root).State);
    }

    [Fact]
    public void The_system_store_is_an_option_that_changes_nothing_for_a_private_ca()
    {
        byte[] signed = Signed();

        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, new VerifyOptions { UseSystemStore = true }));

        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        var both = Assert.Single(PdfSignatureVerifier.Verify(signed, new VerifyOptions { UseSystemStore = true, TrustAnchors = [Pki.Root] }));
        Assert.Equal(SignatureVerdict.Valid, both.Verdict);
    }

    [Fact]
    public void A_file_with_a_password_is_verified_with_it()
    {
        byte[] id = new byte[16];
        var security = PdfSecurity.Create("open", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, id, new Random(2));
        byte[] encrypted = PdfDocument.Open(SignatureKit.Plain()).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));
        byte[] signed = PdfSigner.Sign(encrypted, SignatureKit.Request(Pki) with { Reason = "Because" }, "open");

        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, new VerifyOptions { TrustAnchors = [Pki.Root], Password = "open" }));

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal("Because", report.Reason);
        Assert.Throws<PdfReadException>(() => PdfSignatureVerifier.Verify(signed, Pki.Trusting));
    }
}
