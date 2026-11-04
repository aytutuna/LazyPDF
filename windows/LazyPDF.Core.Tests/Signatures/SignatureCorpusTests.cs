using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

public class SignatureCorpusTests(ITestOutputHelper output)
{
    private static IEnumerable<string>? Corpus()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        return list is null || !File.Exists(list) ? null : File.ReadLines(list).Where(l => l.Length > 0);
    }

    [Fact]
    public void Real_files_are_signed_as_an_update_and_read_back_without_a_throw()
    {
        if (Corpus() is not { } files) return;
        var pki = Pki.Instance;
        int signed = 0, skipped = 0, alreadySigned = 0, valid = 0;
        foreach (string path in files)
        {
            if (!File.Exists(path) || new FileInfo(path).Length > 40_000_000) { skipped++; continue; }
            byte[] file = File.ReadAllBytes(path);
            try
            {
                var existing = PdfSignatureVerifier.Verify(file, pki.Trusting);
                if (existing.Count > 0) alreadySigned++;
                PdfRevisions.List(file);
                byte[] result = PdfSigner.Sign(file, SignatureKit.Request(pki));
                var reports = PdfSignatureVerifier.Verify(result, pki.Trusting);
                Assert.Equal(existing.Count + 1, reports.Count);
                Assert.Equal(SignatureVerdict.Valid, reports[^1].Verdict);
                signed++;
                valid += reports[^1].Verdict == SignatureVerdict.Valid ? 1 : 0;
            }
            catch (PdfReadException)
            {
                skipped++;
            }
        }
        output.WriteLine($"signed {signed}, valid {valid}, already signed {alreadySigned}, skipped {skipped}");
        Assert.Equal(signed, valid);
    }
}
