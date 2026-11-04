using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureSeedTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static PdfObject Parse(string text) => new PdfLexer(new PdfArrayBytes(TestPdf.Latin(text))).ReadObject();

    private static byte[] FieldWith(string seed)
    {
        var document = PdfDocument.Open(SignatureKit.Plain());
        var field = PdfForm.Read(document).AddField(new FieldSpec(FieldKind.Signature, "Approval", 0, new PdfRect(30, 30, 200, 80)));
        field.Dictionary["SV"] = Parse(seed);
        return document.SaveIncremental();
    }

    private static PdfSignRequest Request() => SignatureKit.Request(Pki) with { FieldName = "Approval" };

    private static string Hex(byte[] bytes) => "<" + Convert.ToHexString(bytes) + ">";

    private static SignatureReport Sign(string seed, Func<PdfSignRequest, PdfSignRequest>? change = null) =>
        Assert.Single(SignatureKit.Verify(PdfSigner.Sign(FieldWith(seed), change is null ? Request() : change(Request()))));

    private static string Refused(string seed, Func<PdfSignRequest, PdfSignRequest>? change = null) =>
        Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(FieldWith(seed), change is null ? Request() : change(Request()))).Message;

    [Fact]
    public void A_required_sub_filter_decides_the_format()
    {
        var report = Sign("<</Type /SV /Ff 2 /SubFilter [/adbe.x509.rsa_sha1 /adbe.pkcs7.detached]>>");

        Assert.Equal("adbe.pkcs7.detached", report.SubFilter);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
    }

    [Fact]
    public void A_sub_filter_we_cannot_write_is_refused_when_required_and_ignored_when_not()
    {
        Assert.Equal(SignatureText.SeedFormat, Refused("<</Type /SV /Ff 2 /SubFilter [/adbe.x509.rsa_sha1]>>"));
        Assert.Equal("ETSI.CAdES.detached", Sign("<</Type /SV /SubFilter [/adbe.x509.rsa_sha1]>>").SubFilter);
    }

    [Fact]
    public void Required_reasons_give_the_first_one_or_refuse_another()
    {
        const string Seed = "<</Type /SV /Ff 8 /Reasons [(I have reviewed this) (I approve)]>>";

        Assert.Equal("I have reviewed this", Sign(Seed).Reason);
        Assert.Equal("I approve", Sign(Seed, r => r with { Reason = "I approve" }).Reason);
        Assert.Equal(SignatureText.SeedReason, Refused(Seed, r => r with { Reason = "Because" }));
    }

    [Fact]
    public void A_required_digest_method_is_used()
    {
        byte[] signed = PdfSigner.Sign(FieldWith("<</Type /SV /Ff 64 /DigestMethod [/SHA1 /SHA512]>>"), Request());

        Assert.Equal("2.16.840.1.101.3.4.2.3", CmsSignature.Parse(SignatureKit.Parts(signed).Cms)!.DigestOid);
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
        Assert.Equal(SignatureText.SeedDigest, Refused("<</Type /SV /Ff 64 /DigestMethod [/SHA1]>>"));
    }

    [Fact]
    public void An_MDP_entry_makes_the_signature_a_certification_of_that_level()
    {
        const string Seed = "<</Type /SV /MDP <</P 2>>>>";

        var report = Sign(Seed);

        Assert.Equal(SignatureKind.Certification, report.Kind);
        Assert.Equal(CertificationLevel.FormFill, report.Certification);
        Refused(Seed, r => r with { Certify = CertificationLevel.Annotate });
        Refused("<</Type /SV /MDP <</P 0>>>>", r => r with { Certify = CertificationLevel.FormFill });
    }

    [Fact]
    public void A_required_time_stamp_needs_a_server_and_takes_the_url_from_the_field()
    {
        const string Seed = "<</Type /SV /TimeStamp <</URL (http://seed.test/tsa) /Ff 1>>>>";
        Assert.Equal(SignatureText.NoTimestampServer, Refused(Seed));

        var network = new FakeNetwork();
        var report = Sign(Seed, r => r with { Timestamp = new TimestampSettings(network) });

        Assert.Equal(["http://seed.test/tsa"], network.Requests);
        Assert.Equal(PadesLevel.T, report.Level);
    }

    [Fact]
    public void A_required_revocation_info_raises_the_level_to_LT()
    {
        const string Seed = "<</Type /SV /Ff 32 /AddRevInfo true>>";
        Refused(Seed);

        var report = Sign(Seed, r => r with { Timestamp = new TimestampSettings(new FakeNetwork(), "http://tsa.test/") });

        Assert.Equal(PadesLevel.LT, report.Level);
    }

    [Fact]
    public void Certificate_seed_values_pick_the_signer()
    {
        Assert.Equal(SignatureVerdict.Valid, Sign($"<</Type /SV /Cert <</Ff 1 /Subject [{Hex(Pki.Leaf.RawData)}]>>>>").Verdict);
        Assert.Equal(SignatureText.SeedCertificate, Refused($"<</Type /SV /Cert <</Ff 1 /Subject [{Hex(Pki.LeafEc.RawData)}]>>>>"));

        Assert.Equal(SignatureVerdict.Valid, Sign($"<</Type /SV /Cert <</Ff 2 /Issuer [{Hex(Pki.Intermediate.RawData)}]>>>>").Verdict);
        Refused($"<</Type /SV /Cert <</Ff 2 /Issuer [{Hex(Pki.SelfSigned.RawData)}]>>>>");
    }

    [Fact]
    public void Subject_names_and_key_usage_are_matched()
    {
        Assert.Equal(SignatureVerdict.Valid, Sign("<</Type /SV /Cert <</Ff 8 /SubjectDN [<</CN (Ada Lovelace) /O (Lazy Test)>>]>>>>").Verdict);
        Refused("<</Type /SV /Cert <</Ff 8 /SubjectDN [<</CN (Someone Else)>>]>>>>");

        Assert.Equal(SignatureVerdict.Valid, Sign("<</Type /SV /Cert <</Ff 16 /KeyUsage [(11XXXXXXX)]>>>>").Verdict);
        Refused("<</Type /SV /Cert <</Ff 16 /KeyUsage [(0XXXXXXXX)]>>>>");
    }

    [Fact]
    public void Seed_values_the_field_does_not_mark_required_are_only_advice()
    {
        var report = Sign("<</Type /SV /Reasons [(I approve)] /DigestMethod [/SHA512] /Cert <</Subject []>>>>", r => r with { Reason = "Own reason" });

        Assert.Equal("Own reason", report.Reason);
    }

    [Fact]
    public void Legal_attestation_that_is_required_cannot_be_met()
    {
        Assert.Equal(SignatureText.SeedUnsupported, Refused("<</Type /SV /Ff 16 /LegalAttestation [(This is legal)]>>"));
    }

    [Fact]
    public void A_lock_dictionary_on_the_field_binds_the_signature()
    {
        var document = PdfDocument.Open(SignatureKit.Plain());
        var form = PdfForm.Read(document);
        form.AddField(new FieldSpec(FieldKind.Text, "Name", 0, new PdfRect(30, 100, 200, 124)));
        var field = form.AddField(new FieldSpec(FieldKind.Signature, "Approval", 0, new PdfRect(30, 30, 200, 80)));
        field.Dictionary["Lock"] = Parse("<</Type /SigFieldLock /Action /Include /Fields [(Name)]>>");

        byte[] signed = PdfSigner.Sign(document.SaveIncremental(), Request() with { Certify = CertificationLevel.FormFill });
        byte[] filled = SignatureChangeTests.Edit(signed, d => PdfForm.Read(d).SetValue("Name", "Ada"));

        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Assert.Single(SignatureKit.Verify(filled)).Verdict);
    }
}
