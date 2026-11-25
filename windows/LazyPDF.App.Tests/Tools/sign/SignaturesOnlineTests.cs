using LazyPDF.App.Panels.Signatures;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What asking the certificate servers keeps of the answer.
public sealed class SignaturesOnlineTests
{
    private sealed class Silent : ISignatureTransport
    {
        public byte[]? Post(string url, string contentType, byte[] body) => null;
        public byte[]? Get(string url) => null;
    }

    [Fact]
    public void TheAnswerKeepsTheOfflineChangesAndRevision()
    {
        var changes = new SignatureChangeReport([], 2);
        var offline = new SignatureReport { Index = 0, Revision = 1, CoversWholeFile = false, Level = PadesLevel.T, Changes = changes };
        var other = new SignatureReport { Index = 1, Revision = 2 };
        var asked = new SignatureReport { Index = 0, Revision = 3, CoversWholeFile = true, Level = PadesLevel.LT, RevocationChecked = true };

        var merged = SignaturesSidePanel.Merge([offline, other], [asked]);

        Assert.Equal(2, merged.Count);
        Assert.True(merged[0].RevocationChecked);
        Assert.Equal(1, merged[0].Revision);
        Assert.Equal(PadesLevel.T, merged[0].Level);
        Assert.False(merged[0].CoversWholeFile);
        Assert.Same(changes, merged[0].Changes);
        Assert.Same(other, merged[1]);
    }

    [Fact]
    public void ServersThatDoNotAnswerLeaveTheRowUnchecked()
    {
        var file = ServerPreviewTests.Signed("http://ocsp.test/ocsp", "https://crl.test/ca.crl");
        var options = new VerifyOptions();
        var offline = PdfSignatureVerifier.Verify(file, options);

        var asked = SignaturesSidePanel.Ask(file, null, new Silent(), options, offline);

        Assert.All(asked, r => Assert.False(r.RevocationChecked));
        Assert.Equal(offline.Select(r => r.Revision), asked.Select(r => r.Revision));
    }
}
