using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ViewerSettingsTests
{
    [Fact]
    public void DefaultsWhenTheCatalogSaysNothing()
    {
        var settings = ViewerSettings.Read(StructureFixtures.Open());
        Assert.Equal(new ViewerSettings(null, false, PageMode.UseNone, PageLayout.SinglePage, false, false, false, false, false, false, false, null, null), settings);
    }

    [Fact]
    public void ReadsEverything()
    {
        var document = StructureFixtures.File(
            "/Lang (tr-TR) /PageMode /UseOutlines /PageLayout /TwoPageRight /ViewerPreferences <</DisplayDocTitle true /HideToolbar true /FitWindow true " +
            "/Direction /R2L /PrintScaling /None /Duplex /DuplexFlipLongEdge /NumCopies 3 /HideMenubar false>>");
        var settings = ViewerSettings.Read(document);
        Assert.Equal(("tr-TR", PageMode.UseOutlines, PageLayout.TwoPageRight), (settings.Language, settings.PageMode, settings.PageLayout));
        Assert.True(settings.DisplayDocTitle && settings.HideToolbar && settings.FitWindow && settings.RightToLeft && settings.PrintScalingNone);
        Assert.False(settings.HideMenubar || settings.CenterWindow || settings.HideWindowUI);
        Assert.Equal(("DuplexFlipLongEdge", 3), (settings.Duplex, settings.NumCopies));
    }

    [Fact]
    public void UnknownValuesFallBack()
    {
        var document = StructureFixtures.File("/PageMode /Bogus /PageLayout 5 /ViewerPreferences <</NumCopies 99 /Direction /Sideways>>");
        var settings = ViewerSettings.Read(document);
        Assert.Equal((PageMode.UseNone, PageLayout.SinglePage, null, false), (settings.PageMode, settings.PageLayout, settings.NumCopies, settings.RightToLeft));
    }

    [Fact]
    public void WritesAndReadsBack()
    {
        var document = StructureFixtures.Open();
        var wanted = new ViewerSettings("en-US", true, PageMode.FullScreen, PageLayout.OneColumn, true, true, true, true, true, true, true, "Simplex", 2);
        wanted.Write(document);
        var reopened = StructureFixtures.Reopen(document);
        Assert.Equal(wanted, ViewerSettings.Read(reopened));
    }

    [Fact]
    public void DefaultsAreTakenOutNotWritten()
    {
        var document = StructureFixtures.File("/PageMode /UseThumbs /Lang (de) /ViewerPreferences <</DisplayDocTitle true /Enforce [/PrintScaling] /ViewArea /CropBox>>");
        var read = ViewerSettings.Read(document);
        (read with { DisplayDocTitle = false, PageMode = PageMode.UseNone, Language = null }).Write(document);
        Assert.Null(document.Catalog["PageMode"]);
        Assert.Null(document.Catalog["Lang"]);
        var prefs = document.Dict(document.Catalog, "ViewerPreferences")!;
        Assert.Null(prefs["DisplayDocTitle"]);
        Assert.NotNull(prefs["Enforce"]);
        Assert.NotNull(prefs["ViewArea"]);
    }

    [Fact]
    public void EmptyPreferencesAreDropped()
    {
        var document = StructureFixtures.File("/ViewerPreferences <</HideToolbar true>>");
        (ViewerSettings.Read(document) with { HideToolbar = false }).Write(document);
        Assert.Null(document.Catalog["ViewerPreferences"]);
    }

    [Fact]
    public void LanguageWithNonAsciiIsAString()
    {
        var document = StructureFixtures.Open();
        (ViewerSettings.Read(document) with { Language = "tr" }).Write(document);
        Assert.IsType<PdfString>(document.Catalog["Lang"]);
    }

    [Fact]
    public void IndirectPreferencesAreChangedInPlace()
    {
        var document = StructureFixtures.File("/ViewerPreferences 30 0 R", pdf => pdf.Obj(30, "<</CenterWindow true>>"));
        (ViewerSettings.Read(document) with { HideMenubar = true }).Write(document);
        var prefs = (PdfDictionary)document.Get(30)!;
        Assert.NotNull(prefs["HideMenubar"]);
        Assert.NotNull(prefs["CenterWindow"]);
        Assert.IsType<PdfReference>(document.Catalog["ViewerPreferences"]);
    }
}
