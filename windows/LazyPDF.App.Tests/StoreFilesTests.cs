using System.Text;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// The settings files: lenient decoding, a file that does not decode moved aside.
public sealed class StoreFilesTests
{
    private static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);

    [Fact]
    public void PreferencesAreReadBackAsWritten()
    {
        using var dir = new TempDir();
        AppPreferencesStore.Update(p => { p.Appearance = AppAppearance.Dark; p.SidePanel = "layers"; p.InspectorSections["stamps"] = true; }, dir.Path);

        var loaded = AppPreferencesStore.Load(dir.Path);

        Assert.Equal(AppAppearance.Dark, loaded.Appearance);
        Assert.Equal("layers", loaded.SidePanel);
        Assert.True(loaded.InspectorSections["stamps"]);
    }

    [Fact]
    public void ThumbnailWidthDefaultsAndIsClamped()
    {
        using var dir = new TempDir();
        Assert.Equal(132, AppPreferencesStore.Load(dir.Path).ThumbnailWidth);

        AppPreferencesStore.Update(p => p.ThumbnailWidth = 500, dir.Path);
        Assert.Equal(192, AppPreferencesStore.Load(dir.Path).ThumbnailWidth);
    }

    [Fact]
    public void LanguageIsReadBackAsWrittenAndAnOldFileHasNone()
    {
        using var dir = new TempDir();
        dir.File("preferences.json", Bytes("{\"appearance\":\"dark\"}"));
        Assert.Equal("", AppPreferencesStore.Load(dir.Path).Language);

        AppPreferencesStore.Update(p => p.Language = "tr", dir.Path);

        Assert.Equal("tr", AppPreferencesStore.Load(dir.Path).Language);
    }

    [Fact]
    public void ViewSettingsAreReadBackAsWritten()
    {
        using var dir = new TempDir();
        AppPreferencesStore.Update(p => { p.Tint = Viewer.PageTint.Sepia; p.Columns = 2; p.Cover = true; p.Continuous = false; }, dir.Path);

        var loaded = AppPreferencesStore.Load(dir.Path);

        Assert.Equal(Viewer.PageTint.Sepia, loaded.Tint);
        Assert.Equal(2, loaded.Columns);
        Assert.True(loaded.Cover);
        Assert.False(loaded.Continuous);
    }

    [Fact]
    public void TheWindowPlacementIsReadBackAsWritten()
    {
        using var dir = new TempDir();
        AppPreferencesStore.Update(p => p.Window = new WindowPlacement { Left = -20, Top = 30, Width = 900, Height = 600, Maximized = true }, dir.Path);

        var window = AppPreferencesStore.Load(dir.Path).Window;

        Assert.NotNull(window);
        Assert.Equal(-20, window.Left);
        Assert.Equal(30, window.Top);
        Assert.Equal(900, window.Width);
        Assert.Equal(600, window.Height);
        Assert.True(window.Maximized);
    }

    [Fact]
    public void NoFileGivesTheDefaults()
    {
        using var dir = new TempDir();

        var loaded = AppPreferencesStore.Load(dir.Path);

        Assert.Equal(AppAppearance.System, loaded.Appearance);
        Assert.Equal("pages", loaded.SidePanel);
        Assert.Equal(Viewer.PageTint.None, loaded.Tint);
        Assert.Equal(1, loaded.Columns);
        Assert.False(loaded.Cover);
        Assert.True(loaded.Continuous);
    }

    [Fact]
    public void KeysAreWrittenInCamelCaseAndEnumsAsWords()
    {
        using var dir = new TempDir();
        AppPreferencesStore.Update(p => p.Appearance = AppAppearance.Light, dir.Path);

        string json = File.ReadAllText(Path.Combine(dir.Path, "preferences.json"));

        Assert.Contains("\"appearance\": \"light\"", json);
        Assert.Contains("\"sidePanel\"", json);
    }

    [Fact]
    public void OneBadValueResetsOnlyThatValue()
    {
        using var dir = new TempDir();
        dir.File("preferences.json", Bytes("{\"appearance\":\"purple\",\"sidePanel\":\"search\",\"inspectorSections\":{\"a\":\"yes\"}}"));

        var loaded = AppPreferencesStore.Load(dir.Path);

        Assert.Equal(AppAppearance.System, loaded.Appearance);
        Assert.Equal("search", loaded.SidePanel);
        Assert.Empty(loaded.InspectorSections);
    }

    [Fact]
    public void AMissingKeyKeepsItsDefaultAndAnUnknownKeyIsIgnored()
    {
        using var dir = new TempDir();
        dir.File("preferences.json", Bytes("{\"appearance\":\"dark\",\"somethingNew\":1}"));

        var loaded = AppPreferencesStore.Load(dir.Path);

        Assert.Equal(AppAppearance.Dark, loaded.Appearance);
        Assert.Equal("pages", loaded.SidePanel);
    }

    [Fact]
    public void AFileThatDoesNotDecodeIsMovedAside()
    {
        using var dir = new TempDir();
        dir.File("preferences.json", Bytes("not json at all"));

        var loaded = AppPreferencesStore.Load(dir.Path);

        Assert.Equal(AppAppearance.System, loaded.Appearance);
        Assert.False(File.Exists(Path.Combine(dir.Path, "preferences.json")));
        Assert.Single(Directory.GetFiles(dir.Path, "preferences.unreadable-*.json"));
    }

    [Fact]
    public void UpdateChangesOnlyTheFieldItIsGiven()
    {
        using var dir = new TempDir();
        AppPreferencesStore.Update(p => p.Appearance = AppAppearance.Dark, dir.Path);
        AppPreferencesStore.Update(p => p.SidePanel = "", dir.Path);

        var loaded = AppPreferencesStore.Load(dir.Path);

        Assert.Equal(AppAppearance.Dark, loaded.Appearance);
        Assert.Equal("", loaded.SidePanel);
    }

    [Fact]
    public void TheDefaultFolderIsLazyPdfInAppData() =>
        Assert.Equal(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lazy PDF"), StoreFiles.DefaultDirectory);
}
