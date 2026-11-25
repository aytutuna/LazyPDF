using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class PdfSigningTests
{
    private static readonly Pki Pki = Pki.Instance;

    private static readonly byte[] TinyJpeg = Convert.FromBase64String(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19i" +
        "Z2hnPk1xeXBkeFxlZ2P/2wBDARESEhgVGC8aGi9jQjhCY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2Nj" +
        "Y2NjY2NjY2P/wAARCAAIABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUF" +
        "BAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVW" +
        "V1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi" +
        "4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAEC" +
        "AxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm" +
        "Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq" +
        "8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDHrPoortyj7fy/U9HNPsfP9D//2Q==");

    private sealed class Arial : IFontSource
    {
        public FontFile? Find(string family, FontStyles style)
        {
            string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Fonts), "arial.ttf");
            Assert.True(File.Exists(path), "arial.ttf is missing on this machine; the Turkish signature test needs it.");
            return new FontFile(File.ReadAllBytes(path));
        }
    }

    private sealed class GlyphText : ContentVisitor
    {
        public StringBuilder Text { get; } = new();
        public int Paths { get; private set; }
        public int Images { get; private set; }
        public override void ShowGlyph(ContentContext context, in GlyphInfo glyph) => Text.Append(glyph.Unicode);
        public override void PaintPath(ContentContext context, PathInfo path) => Paths++;
        public override void PaintImage(ContentContext context, ImageInfo image) => Images++;
    }

    private static PdfStream Appearance(PdfDocument document, string field)
    {
        var widget = PdfForm.Read(document).Find(field)!.Widgets[0];
        return document.Stream(document.Dict(widget.Dictionary, "AP"), "N")!;
    }

    private static GlyphText Play(byte[] file, string field)
    {
        var document = PdfDocument.Open(file);
        var visitor = new GlyphText();
        new ContentInterpreter(document).Run(Appearance(document, field), visitor);
        return visitor;
    }

    [Theory]
    [InlineData("rsa")]
    [InlineData("ec")]
    [InlineData("pkcs7")]
    public void Each_key_and_format_signs_and_verifies(string kind)
    {
        var request = kind switch
        {
            "ec" => new PdfSignRequest(Pki.LeafEc, Pki.Signing) { Chain = Pki.Chain },
            "pkcs7" => SignatureKit.Request(Pki) with { Format = SignatureFormat.Pkcs7Detached },
            _ => SignatureKit.Request(Pki),
        };
        byte[] original = SignatureKit.Plain();
        byte[] signed = PdfSigner.Sign(original, request);

        Assert.True(signed.AsSpan(0, original.Length).SequenceEqual(original), "The signature is an update: the file's own bytes stay.");
        var report = Assert.Single(SignatureKit.Verify(signed));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal(kind == "ec" ? "Grace Hopper" : "Ada Lovelace", report.SignerName);
        Assert.Equal(kind == "pkcs7" ? "adbe.pkcs7.detached" : "ETSI.CAdES.detached", report.SubFilter);
        Assert.Equal(kind == "pkcs7" ? PadesLevel.None : PadesLevel.B, report.Level);
        Assert.Equal(Pki.Signing, report.SigningTime);
        Assert.True(report.CoversWholeFile);
        Assert.Equal("Signature1", report.FieldName);
    }

    [Fact]
    public void The_framework_agrees_with_our_reading_of_the_signature()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        var (cms, content) = SignatureKit.Parts(signed);

        var check = new SignedCms(new ContentInfo(content), detached: true);
        check.Decode(cms);
        check.CheckSignature(verifySignatureOnly: true);
        Assert.Equal(Pki.Leaf.Thumbprint, check.SignerInfos[0].Certificate!.Thumbprint);

        content[content.Length / 2] ^= 1;
        var tampered = new SignedCms(new ContentInfo(content), detached: true);
        tampered.Decode(cms);
        Assert.Throws<CryptographicException>(() => tampered.CheckSignature(verifySignatureOnly: true));
    }

    [Fact]
    public void The_byte_range_leaves_exactly_the_contents_out_and_the_file_reopens()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));

        var found = Assert.Single(SignatureScan.Find(signed));
        var range = ((PdfArray)found.Dictionary["ByteRange"]!).Items.Select(i => (int)((PdfNumber)i).Value).ToArray();
        Assert.Equal(0, range[0]);
        Assert.Equal((byte)'<', signed[range[1]]);
        Assert.Equal((byte)'>', signed[range[2] - 1]);
        Assert.Equal(signed.Length, range[2] + range[3]);

        var document = PdfDocument.Open(signed);
        Assert.True(document.IsSigned);
        Assert.Empty(document.Repairs);
        using var pig = UglyToad.PdfPig.PdfDocument.Open(signed);
        Assert.Equal(2, pig.NumberOfPages);
        Assert.Contains("Contract page 1", pig.GetPage(1).Text);
    }

    [Fact]
    public void A_visible_signature_draws_its_text_in_the_rectangle()
    {
        var request = SignatureKit.Request(Pki) with { Rect = new PdfRect(20, 20, 230, 90), Reason = "I approve", Location = "Ankara" };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), request);

        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
        var document = PdfDocument.Open(signed);
        var field = PdfForm.Read(document).Find("Signature1")!;
        Assert.Equal(new PdfRect(20, 20, 230, 90), field.Widgets[0].Rect);
        Assert.Equal(0, field.Widgets[0].PageIndex);
        string shown = Play(signed, "Signature1").Text.ToString();
        Assert.Contains("Digitally signed by Ada Lovelace", shown);
        Assert.Contains("I approve", shown);
        Assert.Contains("Ankara", shown);
        Assert.Equal(new PdfRect(0, 0, 210, 70), document.Rect(Appearance(document, "Signature1").Dictionary, "BBox"));
    }

    [Fact]
    public void A_picture_or_ink_goes_beside_the_text()
    {
        var picture = SignatureKit.Request(Pki) with { Rect = new PdfRect(10, 10, 250, 90), Look = new SignatureLook { Jpeg = TinyJpeg } };
        var visitor = Play(PdfSigner.Sign(SignatureKit.Plain(), picture), "Signature1");
        Assert.Equal(1, visitor.Images);
        Assert.Contains("Digitally signed", visitor.Text.ToString());

        var ink = SignatureKit.Request(Pki) with
        {
            Rect = new PdfRect(10, 10, 250, 90),
            Look = new SignatureLook { Ink = [[(0, 0), (0.5, 1), (1, 0.2)], [(0.2, 0.5), (0.8, 0.5)]], Text = "" },
        };
        var drawn = Play(PdfSigner.Sign(SignatureKit.Plain(), ink), "Signature1");
        Assert.Equal(2, drawn.Paths);
        Assert.Equal("", drawn.Text.ToString());
    }

    [Fact]
    public void Turkish_names_are_embedded_from_the_font_source()
    {
        const string Name = "Ayşe Yılmaz";
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=" + Name, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
        using var certificate = request.CreateSelfSigned(Pki.NotBefore, Pki.NotAfter);

        var sign = new PdfSignRequest(certificate, Pki.Signing) { Rect = new PdfRect(10, 10, 250, 60), Fonts = new Arial() };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), sign);

        Assert.Contains(Name, Play(signed, "Signature1").Text.ToString());
        Assert.Equal(Name, Assert.Single(SignatureKit.Verify(signed)).SignerName);
    }

    [Fact]
    public void Text_no_font_can_draw_is_refused_before_anything_changes()
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=Şeyma", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var certificate = request.CreateSelfSigned(Pki.NotBefore, Pki.NotAfter);

        var e = Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(certificate, Pki.Signing) { Rect = new PdfRect(10, 10, 250, 60) }));
        Assert.Equal(SignatureText.NoFont, e.Message);
    }

    [Fact]
    public void An_empty_signature_field_is_signed_where_it_stands()
    {
        var document = PdfDocument.Open(SignatureKit.Plain());
        PdfForm.Read(document).AddField(new FieldSpec(FieldKind.Signature, "Approval", 1, new PdfRect(30, 30, 200, 80)));
        var session = PdfEditSession.Open(document.SaveIncremental());

        PdfSigner.Sign(session, SignatureKit.Request(Pki) with { FieldName = "Approval" });

        var report = Assert.Single(SignatureKit.Verify(session.Current.ToArray()));
        Assert.Equal("Approval", report.FieldName);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        var form = PdfForm.Read(session.Document);
        var field = form.Find("Approval")!;
        Assert.Equal(1, field.Widgets[0].PageIndex);
        Assert.True(field.IsSigned);
        Assert.Single(form.Fields);
        Assert.Contains("Digitally signed", Play(session.Current.ToArray(), "Approval").Text.ToString());
    }

    [Fact]
    public void A_field_that_is_signed_or_not_a_signature_field_is_refused()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        var again = SignatureKit.Request(Pki) with { FieldName = "Signature1" };
        Assert.Equal(SignatureText.FieldTaken, Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(signed, again)).Message);

        var document = PdfDocument.Open(SignatureKit.Plain());
        PdfForm.Read(document).AddField(new FieldSpec(FieldKind.Text, "Name", 0, new PdfRect(30, 30, 200, 60)));
        byte[] withText = document.SaveIncremental();
        Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(withText, SignatureKit.Request(Pki) with { FieldName = "Name" }));
    }

    [Fact]
    public void A_second_signature_leaves_the_first_valid()
    {
        byte[] first = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        byte[] second = PdfSigner.Sign(first, new PdfSignRequest(Pki.LeafEc, Pki.Signing.AddDays(1)) { Chain = Pki.Chain, Rect = new PdfRect(20, 20, 200, 60) });

        var reports = SignatureKit.Verify(second);
        Assert.Equal(2, reports.Count);
        Assert.All(reports, r => Assert.Equal(SignatureVerdict.Valid, r.Verdict));
        Assert.Equal(["Signature1", "Signature2"], reports.Select(r => r.FieldName));
        Assert.False(reports[0].CoversWholeFile);
        Assert.True(reports[1].CoversWholeFile);
        Assert.Contains(reports[0].Changes.Changes, c => c.Kind == SignatureChangeKind.Signature && c.Allowed);
        Assert.Equal(1, reports[0].Changes.RevisionsAfter);
    }

    [Fact]
    public void Certifying_writes_DocMDP_and_only_the_first_signature_may_do_it()
    {
        var request = SignatureKit.Request(Pki) with { Certify = CertificationLevel.FormFill };
        byte[] certified = PdfSigner.Sign(SignatureKit.Plain(), request);

        var report = Assert.Single(SignatureKit.Verify(certified));
        Assert.Equal(SignatureKind.Certification, report.Kind);
        Assert.Equal(CertificationLevel.FormFill, report.Certification);
        Assert.True(PdfDocument.Open(certified).IsCertified);

        Assert.Equal(SignatureText.NotCertifiable, Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(certified, request)).Message);
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        Assert.Equal(SignatureText.NotCertifiable, Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(signed, request)).Message);
    }

    [Fact]
    public void A_field_lock_is_written_as_FieldMDP_on_the_signature()
    {
        var request = SignatureKit.Request(Pki) with { Lock = new FieldLock(FieldLockAction.Include, ["Name", "Date"]) };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), request);

        var document = PdfDocument.Open(signed);
        var signature = document.Dict(PdfForm.Read(document).Find("Signature1")!.Dictionary, "V")!;
        var reference = (PdfDictionary)document.Resolve(document.Array(signature, "Reference")!.Items[0])!;
        Assert.Equal("FieldMDP", document.Name(reference, "TransformMethod"));
        var parameters = document.Dict(reference, "TransformParams")!;
        Assert.Equal("Include", document.Name(parameters, "Action"));
        Assert.Equal(["Name", "Date"], document.Array(parameters, "Fields")!.Items.Select(i => PdfText.Read(document, i)));
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
    }

    [Fact]
    public void A_cleared_field_can_be_signed_again_whatever_the_cleared_signature_locked()
    {
        var request = SignatureKit.Request(Pki) with { FieldName = "Signature1", Lock = new FieldLock(FieldLockAction.All, []) };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), request);
        var document = PdfDocument.Open(signed);
        var form = PdfForm.Read(document);
        form.ClearSignature(form.Find("Signature1")!);

        byte[] again = PdfSigner.Sign(document.SaveIncremental(), request with { Lock = null });

        Assert.True(PdfForm.Read(PdfDocument.Open(again)).Find("Signature1")!.IsSigned);
    }

    [Fact]
    public void A_cleared_certification_lets_the_file_be_certified_again()
    {
        var request = SignatureKit.Request(Pki) with { FieldName = "Signature1", Certify = CertificationLevel.FormFill };
        byte[] certified = PdfSigner.Sign(SignatureKit.Plain(), request);
        var document = PdfDocument.Open(certified);
        var form = PdfForm.Read(document);
        form.ClearSignature(form.Find("Signature1")!);

        byte[] again = PdfSigner.Sign(document.SaveIncremental(), request);

        Assert.True(PdfDocument.Open(again).IsCertified);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void A_hash_signer_stands_in_for_a_key_that_is_not_here(bool ec)
    {
        var source = ec ? Pki.LeafEc : Pki.Leaf;
        using var publicOnly = X509CertificateLoader.LoadCertificate(source.RawData);
        var calls = new List<string>();
        byte[] Sign(byte[] hash, HashAlgorithmName algorithm)
        {
            calls.Add(algorithm.Name!);
            if (ec)
            {
                using var key = source.GetECDsaPrivateKey()!;
                return key.SignHash(hash, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
            }
            using var rsa = source.GetRSAPrivateKey()!;
            return rsa.SignHash(hash, algorithm, RSASignaturePadding.Pkcs1);
        }

        var request = new PdfSignRequest(publicOnly, Pki.Signing) { Chain = Pki.Chain, Signer = Sign, Digest = HashAlgorithmName.SHA384 };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), request);

        Assert.Equal(["SHA384"], calls);
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
    }

    [Fact]
    public void A_certificate_without_a_key_or_a_signer_is_refused()
    {
        using var publicOnly = X509CertificateLoader.LoadCertificate(Pki.Leaf.RawData);
        var e = Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(SignatureKit.Plain(), new PdfSignRequest(publicOnly, Pki.Signing)));
        Assert.Equal(SignatureText.NoPrivateKey, e.Message);
        Assert.Throws<ArgumentException>(() => PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Digest = HashAlgorithmName.SHA1 }));
        Assert.Throws<ArgumentException>(() => PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Rect = new PdfRect(1, 1, 50, 50), PageIndex = 9 }));
    }

    [Fact]
    public void A_signature_that_outgrows_its_room_is_retried_with_more()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { ReserveBytes = 64 });

        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
        var contents = ((PdfString)SignatureScan.Find(signed)[0].Dictionary["Contents"]!).Bytes;
        Assert.True(contents.Length > 64);
    }

    [Fact]
    public void Signing_a_session_is_one_step_that_undo_takes_back()
    {
        var session = PdfEditSession.Open(SignatureKit.Plain());
        byte[] before = session.Current.ToArray();

        PdfSigner.Sign(session, SignatureKit.Request(Pki));

        Assert.Equal("Sign", session.UndoLabel);
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(PdfSignatureVerifier.Verify(session, Pki.Trusting)).Verdict);
        Assert.True(session.Undo());
        Assert.True(session.Current.Span.SequenceEqual(before));
        Assert.True(session.Redo());
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(PdfSignatureVerifier.Verify(session, Pki.Trusting)).Verdict);
    }

    [Theory]
    [InlineData(PdfCryptStrength.Aes128)]
    [InlineData(PdfCryptStrength.Aes256)]
    public void An_encrypted_file_is_signed_with_its_own_keys(PdfCryptStrength strength)
    {
        byte[] id = new byte[16];
        var security = PdfSecurity.Create("", "owner", PdfPermissions.All, strength, id, new Random(1));
        byte[] encrypted = PdfDocument.Open(SignatureKit.Plain()).SaveRewrite(new PdfSaveOptions(Security: security, DocumentId: id));
        Assert.True(PdfDocument.Open(encrypted).IsEncrypted);

        var request = SignatureKit.Request(Pki) with { Rect = new PdfRect(20, 20, 230, 90), Reason = "Because" };
        byte[] signed = PdfSigner.Sign(encrypted, request);

        var report = Assert.Single(SignatureKit.Verify(signed));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal("Because", report.Reason);
        Assert.Equal("Ada Lovelace", report.SignerName);
        Assert.Contains("Because", Play(signed, "Signature1").Text.ToString());
    }

    [Fact]
    public void A_file_with_a_damaged_cross_reference_is_signed_by_a_full_update()
    {
        byte[] damaged = TestPdf.Replace(SignatureKit.Plain(), "startxref\n", "startxref\n9");
        Assert.True(PdfDocument.Open(damaged).XrefRebuilt);

        byte[] signed = PdfSigner.Sign(damaged, SignatureKit.Request(Pki));

        Assert.False(PdfDocument.Open(signed).XrefRebuilt);
        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
    }

    [Fact]
    public void An_ecdsa_value_with_leading_zero_bytes_is_written_as_a_proper_integer()
    {
        using var publicOnly = X509CertificateLoader.LoadCertificate(Pki.LeafEc.RawData);
        byte[] raw = new byte[64];
        raw[31] = 5;
        raw[34] = 0x80;
        var request = new PdfSignRequest(publicOnly, Pki.Signing) { Chain = Pki.Chain, Signer = (_, _) => raw };

        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), request);

        var cms = CmsSignature.Parse(SignatureKit.Parts(signed).Cms)!;
        var reader = new System.Formats.Asn1.AsnReader(cms.Signature, System.Formats.Asn1.AsnEncodingRules.DER).ReadSequence();
        Assert.Equal(5, (int)reader.ReadInteger());
        Assert.Equal(SignatureVerdict.Broken, Assert.Single(SignatureKit.Verify(signed)).Verdict);
    }
}
