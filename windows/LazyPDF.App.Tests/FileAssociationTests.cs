using LazyPDF.App.Services;
using Microsoft.Win32;
using Xunit;

namespace LazyPDF.App.Tests;

// The registry entries for Open with and lazypdf: addresses. They go under a scratch key, never the real classes.
public sealed class FileAssociationTests : IDisposable
{
    private const string Exe = @"C:\Apps\Lazy PDF\LazyPDF.exe";

    private readonly string _scratch = @"Software\LazyPDF.Tests\" + Guid.NewGuid().ToString("N");
    private readonly RegistryKey _classes;

    public FileAssociationTests() => _classes = Registry.CurrentUser.CreateSubKey(_scratch);

    public void Dispose()
    {
        _classes.Dispose();
        Registry.CurrentUser.DeleteSubKeyTree(_scratch, throwOnMissingSubKey: false);
    }

    private string? Value(string key, string name = "")
    {
        using var open = _classes.OpenSubKey(key);
        return open?.GetValue(name) as string;
    }

    [Fact]
    public void TheSchemeOpensTheAppWithTheAddress()
    {
        FileAssociation.Register(_classes, Exe);

        Assert.Equal("URL:Lazy PDF", Value("lazypdf"));
        Assert.Equal("", Value("lazypdf", "URL Protocol"));
        Assert.Equal("\"" + Exe + "\" \"%1\"", Value(@"lazypdf\shell\open\command"));
    }

    [Fact]
    public void TheAppIsInTheOpenWithListForPdfs()
    {
        FileAssociation.Register(_classes, Exe);

        Assert.Equal("Lazy PDF", Value(@"Applications\LazyPDF.exe", "FriendlyAppName"));
        Assert.Equal("", Value(@"Applications\LazyPDF.exe\SupportedTypes", ".pdf"));
        Assert.Equal("", Value(@".pdf\OpenWithProgids", FileAssociation.ProgId));
        Assert.True(FileAssociation.IsRegistered(_classes));
    }

    [Fact]
    public void ItNeverBecomesTheDefaultProgram()
    {
        FileAssociation.Register(_classes, Exe);

        Assert.Null(Value(".pdf"));
        Assert.DoesNotContain(FileAssociation.Entries(Exe), e => e.Key == ".pdf" && e.Name == "");
        Assert.DoesNotContain(FileAssociation.Entries(Exe), e => e.Key.Contains("UserChoice"));
    }

    [Fact]
    public void RegisteringAgainChangesNothing()
    {
        Assert.True(FileAssociation.Register(_classes, Exe));
        Assert.False(FileAssociation.Register(_classes, Exe));
    }

    [Fact]
    public void ARegisteredAppMovedToAnotherFolderIsWrittenAgain()
    {
        FileAssociation.Register(_classes, Exe);

        Assert.True(FileAssociation.Register(_classes, @"D:\Moved\LazyPDF.exe"));
        Assert.Equal("\"D:\\Moved\\LazyPDF.exe\" \"%1\"", Value(@"lazypdf\shell\open\command"));
    }

    [Fact]
    public void UnregisteringTakesEverythingOutAndLeavesOtherProgramsAlone()
    {
        using (var others = _classes.CreateSubKey(@".pdf\OpenWithProgids")) others.SetValue("Other.Reader", "");
        FileAssociation.Register(_classes, Exe);

        Assert.True(FileAssociation.Unregister(_classes));

        Assert.False(FileAssociation.IsRegistered(_classes));
        Assert.Null(Value("lazypdf"));
        Assert.Null(Value(@"Applications\LazyPDF.exe\shell\open\command"));
        Assert.Equal("", Value(@".pdf\OpenWithProgids", "Other.Reader"));
        Assert.False(FileAssociation.Unregister(_classes));
    }

    [Fact]
    public void NothingIsRegisteredUntilTheUserAsks()
    {
        Assert.False(FileAssociation.IsRegistered(_classes));
    }
}
