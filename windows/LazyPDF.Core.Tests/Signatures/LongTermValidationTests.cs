using System.Security.Cryptography;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class LongTermValidationTests
{
    private static readonly Pki Pki = Pki.Instance;
    private const string Tsa = "http://tsa.test/";

    private static PdfSignRequest Request(FakeNetwork network, PadesLevel level) =>
        SignatureKit.Request(Pki) with { Timestamp = new TimestampSettings(network, Tsa), Level = level };

    private static (int Certs, int Ocsps, int Crls, PdfDictionary Vri) Dss(byte[] file)
    {
        var document = PdfDocument.Open(file);
        var dss = document.Dict(document.Catalog, "DSS")!;
        return (document.Array(dss, "Certs")?.Items.Count ?? 0, document.Array(dss, "OCSPs")?.Items.Count ?? 0,
                document.Array(dss, "CRLs")?.Items.Count ?? 0, document.Dict(dss, "VRI")!);
    }

    [Fact]
    public void B_LT_carries_the_chain_and_its_revocation_data_in_the_file()
    {
        var network = new FakeNetwork();
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(network, PadesLevel.LT));

        var report = Assert.Single(SignatureKit.Verify(signed));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal(PadesLevel.LT, report.Level);
        Assert.True(report.RevocationChecked);

        var (certs, ocsps, crls, vri) = Dss(signed);
        Assert.True(certs >= 4, "leaf, intermediate, root and the time stamp authority");
        Assert.Equal(1, ocsps);
        Assert.Equal(1, crls);
        var key = Convert.ToHexString(SHA1.HashData(SignatureKit.Parts(signed).Cms));
        var entry = (PdfDictionary)PdfDocument.Open(signed).Resolve(vri[key])!;
        Assert.Equal("VRI", ((PdfName)entry["Type"]!).Value);
        Assert.NotNull(entry["Cert"]);
        Assert.NotNull(entry["OCSP"]);
        Assert.Contains(Pki.OcspUrl, network.Requests);
        Assert.Contains(Pki.IssuerUrl, network.Requests.Concat([Pki.IssuerUrl]));
        using var pig = UglyToad.PdfPig.PdfDocument.Open(signed);
        Assert.Equal(2, pig.NumberOfPages);
    }

    [Fact]
    public void The_validation_data_alone_is_enough_to_check_revocation_offline()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(new FakeNetwork(), PadesLevel.LT));

        // The signature's own certificates are removed from nothing here: revocation comes from the /DSS, not a network.
        var report = Assert.Single(PdfSignatureVerifier.Verify(signed, Pki.Trusting));

        Assert.True(report.RevocationChecked);
        Assert.Empty(report.Problems);
    }

    [Fact]
    public void A_certificate_revoked_before_signing_makes_the_signature_untrusted()
    {
        var network = new FakeNetwork { Revoked = true };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(network, PadesLevel.LT));

        var report = Assert.Single(SignatureKit.Verify(signed));

        Assert.Equal(SignatureVerdict.ValidButUntrusted, report.Verdict);
        Assert.Contains(SignatureProblem.CertificateRevoked, report.Problems);
        Assert.False(report.RevocationChecked);
    }

    [Fact]
    public void A_revocation_after_signing_does_not_undo_the_signature()
    {
        var network = new FakeNetwork { Revoked = true, RevokedAt = Pki.Signing.AddDays(30) };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(network, PadesLevel.LT));

        Assert.Equal(SignatureVerdict.Valid, Assert.Single(SignatureKit.Verify(signed)).Verdict);
    }

    [Fact]
    public void A_crl_stands_in_when_the_ocsp_responder_is_down()
    {
        var network = new FakeNetwork { OcspDown = true };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(network, PadesLevel.LT));

        var (_, ocsps, crls, _) = Dss(signed);
        Assert.Equal(0, ocsps);
        Assert.Equal(2, crls);
        Assert.True(Assert.Single(SignatureKit.Verify(signed)).RevocationChecked);
    }

    [Fact]
    public void A_revoked_certificate_is_found_in_a_crl_too()
    {
        var network = new FakeNetwork { OcspDown = true, Revoked = true };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(network, PadesLevel.LT));

        Assert.Contains(SignatureProblem.CertificateRevoked, Assert.Single(SignatureKit.Verify(signed)).Problems);
    }

    [Fact]
    public void Nothing_to_ask_leaves_the_certificate_without_data_and_the_level_at_T()
    {
        var network = new FakeNetwork { OcspDown = true, CrlDown = true };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(network, PadesLevel.LT));

        var report = Assert.Single(SignatureKit.Verify(signed));
        Assert.Equal(PadesLevel.T, report.Level);
        Assert.False(report.RevocationChecked);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
    }

    [Fact]
    public void B_LTA_ends_with_a_document_time_stamp_over_everything()
    {
        var network = new FakeNetwork { StampTime = Pki.Signing.AddMinutes(5) };
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), Request(network, PadesLevel.LTA));

        var reports = SignatureKit.Verify(signed);

        Assert.Equal(2, reports.Count);
        Assert.Equal(PadesLevel.LTA, reports[0].Level);
        Assert.Equal(SignatureVerdict.Valid, reports[0].Verdict);
        Assert.Equal(SignatureKind.DocumentTimestamp, reports[1].Kind);
        Assert.Equal("ETSI.RFC3161", reports[1].SubFilter);
        Assert.Equal(SignatureVerdict.Valid, reports[1].Verdict);
        Assert.Equal(Pki.Signing.AddMinutes(5), reports[1].TimestampTime);
        Assert.True(reports[1].CoversWholeFile);
        Assert.Equal(["Signature1", "Timestamp1"], reports.Select(r => r.FieldName));
        Assert.Equal("Time stamped on 10 Mar 2026. Not changed since.", reports[1].Sentence);
        Assert.All(reports[0].Changes.Changes, c => Assert.True(c.Allowed));
        Assert.Contains(reports[0].Changes.Changes, c => c.Kind == SignatureChangeKind.ValidationData);
        Assert.Contains(reports[0].Changes.Changes, c => c.Kind == SignatureChangeKind.Signature);
    }

    [Fact]
    public void A_document_time_stamp_can_be_added_to_any_file_and_a_change_under_it_breaks_it()
    {
        var network = new FakeNetwork();
        byte[] stamped = PdfSigner.AddDocumentTimestamp(SignatureKit.Plain(), new TimestampSettings(network, Tsa), Pki.Signing);

        var report = Assert.Single(SignatureKit.Verify(stamped));
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Null(report.SignerName);
        Assert.Equal(2, PdfDocument.Open(stamped).Pages.Count);

        Assert.Equal(SignatureVerdict.Broken, Assert.Single(SignatureKit.Verify(TestPdf.Replace(stamped, "Contract page 1", "Contract page 7"))).Verdict);
        var late = SignatureChangeTests.Edit(stamped, d => d.Stream(d.Pages[0].Dictionary, "Contents")!.Data = TestPdf.Latin("BT ET"));
        Assert.Equal(SignatureVerdict.ChangedAfterSigning, Assert.Single(SignatureKit.Verify(late)).Verdict);
    }

    [Fact]
    public void A_document_time_stamp_needs_a_server_and_a_page()
    {
        Assert.Throws<InvalidOperationException>(() => PdfSigner.AddDocumentTimestamp(SignatureKit.Plain(), new TimestampSettings(new FakeNetwork()), Pki.Signing));
        Assert.Throws<InvalidOperationException>(() => PdfSigner.AddDocumentTimestamp(SignatureKit.Plain(), new TimestampSettings(new FakeNetwork { StampDown = true }, Tsa), Pki.Signing));
    }

    [Fact]
    public void Validation_data_may_be_added_to_a_signed_file_later_and_only_once()
    {
        var network = new FakeNetwork();
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));
        Assert.False(Assert.Single(SignatureKit.Verify(signed)).RevocationChecked);

        byte[] withData = PdfLongTermValidation.Add(signed, network, Pki.Signing.AddDays(1));

        Assert.True(withData.Length > signed.Length);
        Assert.True(withData.AsSpan(0, signed.Length).SequenceEqual(signed));
        var report = Assert.Single(SignatureKit.Verify(withData));
        Assert.True(report.RevocationChecked);
        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.True(PdfLongTermValidation.Add(withData, network, Pki.Signing.AddDays(2)).AsSpan().SequenceEqual(withData));
    }

    [Fact]
    public void Validation_data_is_allowed_after_a_certification_that_allows_no_changes()
    {
        byte[] certified = SignatureChangeTests.Certified(CertificationLevel.NoChanges);
        byte[] ltv = PdfLongTermValidation.Add(certified, new FakeNetwork(), Pki.Signing.AddDays(1));
        byte[] stamped = PdfSigner.AddDocumentTimestamp(ltv, new TimestampSettings(new FakeNetwork(), Tsa), Pki.Signing);

        var report = SignatureKit.Verify(stamped)[0];

        Assert.Equal(SignatureVerdict.Valid, report.Verdict);
        Assert.Equal(SignatureKind.Certification, report.Kind);
        Assert.All(report.Changes.Changes, c => Assert.True(c.Allowed));
    }

    [Fact]
    public void The_servers_validation_data_would_ask_are_listed_without_asking()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki));

        var servers = PdfLongTermValidation.Servers(signed);

        Assert.Equal(
            [(ValidationServerKind.Ocsp, Pki.OcspUrl, "ocsp.test"), (ValidationServerKind.Crl, Pki.CrlUrl, "crl.test"), (ValidationServerKind.Crl, Pki.RootCrlUrl, "crl.test")],
            servers.Select(s => (s.Kind, s.Url, s.Host)));
        Assert.Equal(servers, PdfLongTermValidation.Servers(PdfEditSession.Open(signed)));
    }

    [Fact]
    public void A_chain_that_stops_short_of_a_root_lists_the_top_certificates_own_links_too()
    {
        byte[] signed = PdfSigner.Sign(SignatureKit.Plain(), SignatureKit.Request(Pki) with { Chain = [] });

        var servers = PdfLongTermValidation.Servers(signed);

        Assert.Equal(
            [(ValidationServerKind.CaIssuers, Pki.IssuerUrl, "ca.test"), (ValidationServerKind.Ocsp, Pki.OcspUrl, "ocsp.test"), (ValidationServerKind.Crl, Pki.CrlUrl, "crl.test")],
            servers.Select(s => (s.Kind, s.Url, s.Host)));
    }

    [Fact]
    public void A_file_without_signatures_has_no_servers_to_list()
    {
        Assert.Equal(SignatureText.NotSigned, Assert.Throws<InvalidOperationException>(() => PdfLongTermValidation.Servers(SignatureKit.Plain())).Message);
    }

    [Fact]
    public void A_file_without_signatures_has_nothing_to_add_data_to()
    {
        var e = Assert.Throws<InvalidOperationException>(() => PdfLongTermValidation.Add(SignatureKit.Plain(), new FakeNetwork(), Pki.Signing));
        Assert.Equal(SignatureText.NotSigned, e.Message);
    }

    [Fact]
    public void A_session_gets_one_step_for_each_part_and_undo_goes_back_through_them()
    {
        var session = PdfEditSession.Open(SignatureKit.Plain());
        PdfSigner.Sign(session, Request(new FakeNetwork(), PadesLevel.LTA));

        Assert.Equal("Time stamp", session.UndoLabel);
        Assert.Equal(2, PdfSignatureVerifier.Verify(session, Pki.Trusting).Count);
        Assert.True(session.Undo());
        Assert.Equal("Validation data", session.UndoLabel);
        Assert.True(session.Undo());
        Assert.Equal("Sign", session.UndoLabel);
        Assert.Equal(PadesLevel.T, Assert.Single(PdfSignatureVerifier.Verify(session, Pki.Trusting)).Level);
    }

    [Fact]
    public void Levels_without_a_time_stamp_server_are_refused()
    {
        var request = SignatureKit.Request(Pki) with { Level = PadesLevel.LT };
        Assert.Throws<InvalidOperationException>(() => PdfSigner.Sign(SignatureKit.Plain(), request));
    }
}
