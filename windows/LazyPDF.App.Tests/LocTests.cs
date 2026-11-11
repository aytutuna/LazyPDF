using System.Globalization;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Loc.T and Loc.Plural: English is the key and the fallback, Turkish comes from Strings.tr.resx.
public sealed class LocTests
{
    private static T In<T>(string culture, Func<T> body)
    {
        var saved = CultureInfo.CurrentUICulture;
        CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo(culture);
        try { return body(); }
        finally { CultureInfo.CurrentUICulture = saved; }
    }

    private static T InTurkish<T>(Func<T> body) => In("tr", body);

    private static T InEnglish<T>(Func<T> body) => In("en-US", body);

    [Fact]
    public void EnglishIsTheKeyAndComesBackUnchanged() =>
        Assert.Equal("Cancel", InEnglish(() => Loc.T("Cancel")));

    [Fact]
    public void ATextWithNoEntryComesBackAsWritten() =>
        Assert.Equal("No entry for this", InTurkish(() => Loc.T("No entry for this")));

    [Fact]
    public void CancelIsIptalInTurkish() =>
        Assert.Equal("İptal", InTurkish(() => Loc.T("Cancel")));

    [Fact]
    public void BackToTheFileTooltipInTurkish() =>
        Assert.Equal("Dosyaya dön (Esc)", InTurkish(() => Loc.T("Back to the file (Esc)")));

    [Fact]
    public void ValuesFillTheNumberedPlaces()
    {
        Assert.Equal("Page 3 of 12", InEnglish(() => Loc.T("Page {0} of {1}", 3, 12)));
        Assert.Equal("Sayfa 3/12", InTurkish(() => Loc.T("Page {0} of {1}", 3, 12)));
    }

    [Fact]
    public void AValueThatHoldsABraceIsLeftAlone() =>
        Assert.Equal("Removed: {1}", InEnglish(() => Loc.T("Removed: {0}", "{1}")));

    [Fact]
    public void APlaceWithNoValueStaysAsWritten() =>
        Assert.StartsWith("Pages with only pictures: 3{1}.", InEnglish(() => Loc.T("Pages with only pictures: {0}{1}. Run text recognition so the words can be read.", 3)));

    [Fact]
    public void TheContextAfterTheBarIsNeverShownInEnglish() =>
        Assert.Equal("page 4", InEnglish(() => Loc.T("page {0}|in a sentence", 4)));

    [Fact]
    public void NumbersAreWrittenInTheCurrentFormat()
    {
        Assert.Equal("1,234.5", InEnglish(() => Loc.T("{0}", 1234.5)));
        Assert.Equal("3.14", InEnglish(() => Loc.T("{0}", Math.Round(Math.PI, 2))));
    }

    [Fact]
    public void PluralTakesOneFormForOneAndTheOtherFormForTheRest()
    {
        Assert.Equal("1 difference", InEnglish(() => Loc.Plural(1, "{0} difference", "{0} differences")));
        Assert.Equal("0 differences", InEnglish(() => Loc.Plural(0, "{0} difference", "{0} differences")));
        Assert.Equal("5 differences", InEnglish(() => Loc.Plural(5, "{0} difference", "{0} differences")));
    }

    [Fact]
    public void TurkishUsesOneFormAfterANumber()
    {
        Assert.Equal("1 fark", InTurkish(() => Loc.Plural(1, "{0} difference", "{0} differences")));
        Assert.Equal("5 fark", InTurkish(() => Loc.Plural(5, "{0} difference", "{0} differences")));
    }

    [Fact]
    public void TheCoreTextsGoThroughLoc()
    {
        Assert.Equal("Belge etiketli", InTurkish(() => AccessibilityText.Name(AccessibilityRule.Tagged)));
        Assert.Equal("Document is tagged", InEnglish(() => AccessibilityText.Name(AccessibilityRule.Tagged)));
        Assert.Equal("2 fark", InTurkish(() => CompareText.ChangeCount(2)));
        Assert.Equal("1 difference", InEnglish(() => CompareText.ChangeCount(1)));
    }

    [Fact]
    public void TheTestTableStandsInForTheResources()
    {
        Loc.Table = new Dictionary<string, string> { ["Cancel"] = "Stop" };
        try
        {
            Assert.Equal("Stop", Loc.T("Cancel"));
            Assert.Equal("Save", Loc.T("Save"));
        }
        finally
        {
            Loc.Table = null;
        }
    }

    public static TheoryData<string[]> DialogButtons => new()
    {
        new[] { "_Open", "_Cancel" },
        new[] { "_Save", "Do_n't save", "_Cancel" },
        new[] { "_Save", "C_lose", "_Cancel" },
        new[] { "_Restore", "_Discard" },
        new[] { "C_reate", "_Cancel" },
        new[] { "_Cancel", "C_lose" },
    };

    private static char AccessKey(string text) => char.ToLowerInvariant(text[text.IndexOf('_') + 1]);

    [Theory]
    [MemberData(nameof(DialogButtons))]
    public void AccessKeysInADialogAreDistinct(string[] keys)
    {
        Assert.Equal(keys.Length, InEnglish(() => keys.Select(k => AccessKey(Loc.T(k))).Distinct().Count()));
        Assert.Equal(keys.Length, InTurkish(() => keys.Select(k => AccessKey(Loc.T(k))).Distinct().Count()));
    }

    [Theory]
    [MemberData(nameof(DialogButtons))]
    public void NoTurkishAccessKeyIsADottedOrDotlessI(string[] keys)
    {
        foreach (string key in keys)
            Assert.DoesNotContain(InTurkish(() => AccessKey(Loc.T(key))), "iı");
    }
}
