using LazyPDF.App.Tools.Ocr;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class OcrPagesTests
{
    [Fact]
    public void PagesThatNeedReadingComeFirstInPageOrder()
    {
        var rows = OcrPages.Rows([OcrPageKind.Text, OcrPageKind.Picture, OcrPageKind.Blank, OcrPageKind.Drawing, OcrPageKind.Picture, OcrPageKind.OwnLayer]);

        Assert.Equal([1, 4, 3, 5, 0, 2], rows.Select(r => r.Page));
    }

    [Fact]
    public void OnlyScansAndDrawingsAreWantedUnlessLayersAreReplaced()
    {
        var own = new PageRow(0, OcrPageKind.OwnLayer);

        Assert.True(OcrPages.Wanted(new PageRow(0, OcrPageKind.Picture), replace: false));
        Assert.False(OcrPages.Wanted(new PageRow(0, OcrPageKind.Text), replace: false));
        Assert.False(OcrPages.Wanted(own, replace: false));
        Assert.True(OcrPages.Wanted(own, replace: true));
    }

    [Fact]
    public void ARowSaysPageAndKindToAScreenReader()
    {
        Assert.Equal("Page 3, Scan", new PageRow(2, OcrPageKind.Picture).ToString());
    }

    [Fact]
    public void TriageReadsACopyOfTheFile()
    {
        Assert.Equal([OcrPageKind.Text, OcrPageKind.Text], OcrPages.Classify(Pdfs.Text(2), null, null));
    }

    [Fact]
    public void ALockedFileIsOpenedWithItsPassword()
    {
        var bytes = Pdfs.Restricted(PdfPermissions.None);

        Assert.Equal([OcrPageKind.Text], OcrPages.Classify(bytes, "owner", null));
    }
}

public sealed class OcrLanguageStateTests
{
    private static readonly OcrLanguage English = new("en-US", "English");
    private static readonly OcrLanguage Turkish = new("tr-TR", "Turkish");

    [Fact]
    public void WithNoLanguageTheAdviceSaysWhereToAddOne()
    {
        var state = new OcrLanguageState([], ["Turkish"]);

        Assert.Contains("No OCR language", state.Advice);
        Assert.Contains("Turkish", state.Advice);
        Assert.Contains("Optical character recognition", state.Advice);
        Assert.Null(state.Preferred());
    }

    [Fact]
    public void AMissingLanguageIsNamedAndSentToItsOptions()
    {
        var state = new OcrLanguageState([English], ["Turkish", "German"]);

        Assert.StartsWith("No OCR for Turkish, German. Open its options", state.Advice);
        Assert.EndsWith("if it is listed.", state.Advice);
    }

    [Fact]
    public void WhenNothingIsMissingTheAdviceStillSaysHowToAddMore()
    {
        var state = new OcrLanguageState([English], []);

        Assert.StartsWith("Need another language?", state.Advice);
    }

    [Fact]
    public void TheListStartsOnTheLanguageOfTheAppElseEnglish()
    {
        var old = App.WindowsLanguage;
        try
        {
            App.WindowsLanguage = new("tr-TR");
            Assert.Equal(Turkish, new OcrLanguageState([English, Turkish], []).Preferred());

            App.WindowsLanguage = new("fr-FR");
            Assert.Equal(English, new OcrLanguageState([Turkish, English], []).Preferred());
            Assert.Equal(Turkish, new OcrLanguageState([Turkish], []).Preferred());
        }
        finally
        {
            App.WindowsLanguage = old;
        }
    }
}
