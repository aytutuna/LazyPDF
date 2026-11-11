using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SignatureTextTests
{
    private static readonly DateTimeOffset Time = new(2026, 3, 10, 9, 30, 0, TimeSpan.Zero);

    private static SignatureReport Report(SignatureVerdict verdict) =>
        new() { Verdict = verdict, SignerName = "Ada Lovelace", SigningTime = Time };

    [Theory]
    [InlineData(SignatureVerdict.Valid, "Signed by Ada Lovelace on 10 Mar 2026. Not changed since.")]
    [InlineData(SignatureVerdict.ValidButUntrusted, "Signed by Ada Lovelace on 10 Mar 2026. The signer is not trusted.")]
    [InlineData(SignatureVerdict.ChangedAfterSigning, "Signed by Ada Lovelace on 10 Mar 2026. Changed since.")]
    [InlineData(SignatureVerdict.Broken, "The signature by Ada Lovelace is not valid.")]
    [InlineData(SignatureVerdict.Unknown, "This signature could not be checked.")]
    public void Each_verdict_has_one_plain_sentence(SignatureVerdict verdict, string sentence)
    {
        Assert.Equal(sentence, Report(verdict).Sentence);
    }

    [Fact]
    public void Allowed_changes_and_missing_facts_are_said_plainly()
    {
        var allowed = Report(SignatureVerdict.Valid) with { Changes = new SignatureChangeReport([new SignatureChange(SignatureChangeKind.FormFill, 5, -1, "Name", true)], 1) };
        Assert.Equal("Signed by Ada Lovelace on 10 Mar 2026. Changed only as the signer allowed.", allowed.Sentence);

        var nameless = new SignatureReport { Verdict = SignatureVerdict.Valid };
        Assert.Equal("Signed by an unknown signer. Not changed since.", nameless.Sentence);

        var stamp = new SignatureReport { Verdict = SignatureVerdict.Valid, Kind = SignatureKind.DocumentTimestamp, TimestampTime = Time };
        Assert.Equal("Time stamped on 10 Mar 2026. Not changed since.", stamp.Sentence);
    }

    [Fact]
    public void A_signer_that_only_has_an_expired_certificate_says_so()
    {
        var report = Report(SignatureVerdict.ValidButUntrusted) with { Problems = [SignatureProblem.CertificateExpired] };
        Assert.Equal("Signed by Ada Lovelace on 10 Mar 2026. The certificate has expired since.", report.Sentence);
        Assert.Equal("Certificate has expired", SignatureText.Status(report));

        var more = report with { Problems = [SignatureProblem.CertificateExpired, SignatureProblem.WeakDigest] };
        Assert.Equal("Signed by Ada Lovelace on 10 Mar 2026. The signer is not trusted.", more.Sentence);
        Assert.Equal("Signer is not trusted", SignatureText.Status(more));
    }

    [Fact]
    public void A_status_line_is_six_words_at_most()
    {
        foreach (var verdict in Enum.GetValues<SignatureVerdict>())
        {
            string line = SignatureText.Status(verdict);
            Assert.InRange(line.Split(' ').Length, 1, 6);
            Assert.False(line.EndsWith('.'));
        }
        Assert.Equal(5, Enum.GetValues<SignatureVerdict>().Select(SignatureText.Status).Distinct().Count());
    }

    [Fact]
    public void Every_problem_has_a_title_and_something_to_do()
    {
        foreach (var problem in Enum.GetValues<SignatureProblem>())
        {
            string title = SignatureText.Title(problem), advice = SignatureText.Advice(problem);
            Assert.NotEmpty(title);
            Assert.NotEmpty(advice);
            Assert.False(title.EndsWith('.'));
            Assert.EndsWith(".", advice);
        }
        Assert.Equal(Enum.GetValues<SignatureProblem>().Length, Enum.GetValues<SignatureProblem>().Select(SignatureText.Title).Distinct().Count());
    }

    [Fact]
    public void Every_kind_of_change_is_described()
    {
        foreach (var kind in Enum.GetValues<SignatureChangeKind>())
        {
            Assert.NotEmpty(SignatureText.Describe(new SignatureChange(kind, 1, 2, null, false)));
        }
        Assert.Equal("Page content changed on page 3", SignatureText.Describe(new SignatureChange(SignatureChangeKind.PageContent, 1, 2, null, false)));
        Assert.Equal("Form filled in field Name", SignatureText.Describe(new SignatureChange(SignatureChangeKind.FormFill, 1, -1, "Name", true)));
    }
}
