using LazyPDF.App.Documents;
using LazyPDF.App.Tools.Optimize;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class OutputChoiceTests
{
    [Fact]
    public Task AReadOnlyFileCannotBeReplacedUntilItIsSavedAsANewFile() => Sta.Run(() =>
    {
        using var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2)), new FakeRenderer(), "a.pdf", "a.pdf") { ReadOnly = true };
        var choice = new OutputChoice();

        choice.Configure(tab, removesSignatures: false);

        Assert.False(choice.ThisFile.IsEnabled);
        Assert.True(choice.NewFile.IsChecked);
        Assert.False(choice.Replace);
        Assert.Equal("This file is read-only. The result opens in a new tab.", choice.Note.Text);

        tab.ReadOnly = false;
        choice.Configure(tab, removesSignatures: false);

        Assert.True(choice.ThisFile.IsEnabled);
        return Task.CompletedTask;
    });
}
