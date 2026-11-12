using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Panels.Signatures;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class ClearSignatureTests
{
    private static DocumentTab Open(byte[] file) => new(PdfEditSession.Open(file), new FakeRenderer(), null, "a.pdf", null);

    private static SignatureRow RowOf(byte[] file) =>
        new(Assert.Single(PdfSignatureVerifier.Verify(file, new VerifyOptions())), 0, Rect.Empty);

    [Fact]
    public Task ClearingEmptiesTheFieldInOneUndoStep() => Sta.Run(() =>
    {
        var file = ServerPreviewTests.Signed("http://ocsp.test/ocsp", "https://crl.test/ca.crl");
        using var tab = Open(file);
        var row = RowOf(file);
        string name = row.Report.FieldName!;
        var signed = SignaturesSidePanel.SignedFields(tab);
        Assert.Contains(name, signed);
        Assert.True(SignaturesSidePanel.CanClear(tab, signed, row));

        Assert.True(SignaturesSidePanel.Clear(tab, name));

        Assert.Empty(SignaturesSidePanel.SignedFields(tab));
        Assert.False(SignaturesSidePanel.CanClear(tab, SignaturesSidePanel.SignedFields(tab), row));
        Assert.True(tab.Undo());
        Assert.Contains(name, SignaturesSidePanel.SignedFields(tab));
        return Task.CompletedTask;
    });

    [Fact]
    public Task AFieldThatIsNotSignedIsNotOffered() => Sta.Run(() =>
    {
        var file = ServerPreviewTests.Signed("http://ocsp.test/ocsp", "https://crl.test/ca.crl");
        using var tab = Open(file);
        var row = RowOf(file);

        Assert.False(SignaturesSidePanel.CanClear(tab, [], row));
        Assert.False(SignaturesSidePanel.CanClear(tab, [row.Report.FieldName!], new SignatureRow(new SignatureReport(), -1, Rect.Empty)));
        return Task.CompletedTask;
    });

    [Fact]
    public Task ClearingAFieldThatIsNotSignedIsReportedAndChangesNothing() => Sta.Run(() =>
    {
        using var tab = Open(Pdfs.Text());
        Problem? told = null;

        Assert.False(SignaturesSidePanel.Clear(tab, "Nothing", p => told = p));

        Assert.NotNull(told);
        Assert.False(tab.Session.CanUndo);
        return Task.CompletedTask;
    });
}
