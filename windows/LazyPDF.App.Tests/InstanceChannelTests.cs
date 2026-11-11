using System.Collections.Concurrent;
using System.Text;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

// From Lazy Print's InstanceChannelTests: the message a second start sends the first, a JSON array of
// paths over the pipe LazyPDF.Open.
public sealed class InstanceChannelTests
{
    // The listener waits for a pool thread, which can take seconds while the other tests keep a CI runner busy.
    private const int Patient = 30_000;

    private static string UniquePipe() => "LazyPDF.Open.test-" + Guid.NewGuid().ToString("N");

    [Fact]
    public void ThePipeAndTheMutexCarryTheAppsName()
    {
        Assert.StartsWith("LazyPDF.Open.", InstanceChannel.PipeName);
        Assert.Matches(@"^LazyPDF\.Open\.\d+$", InstanceChannel.PipeName);
    }

    [Fact]
    public void PathsGoAsAJsonArrayOfStrings()
    {
        byte[] message = InstanceChannel.Encode([@"C:\Docs\a.pdf", @"C:\Docs\b.jpg"]);

        Assert.Equal("[\"C:\\\\Docs\\\\a.pdf\",\"C:\\\\Docs\\\\b.jpg\"]", Encoding.UTF8.GetString(message));
    }

    [Fact]
    public void PathsComeBackAsTheyWentIncludingQuotesAndLetters()
    {
        string[] paths = ["C:\\Docs\\M\u00fcller \"final\".pdf", "\\\\server\\share\\\u65e5\u672c\u8a9e.png"];

        Assert.Equal(paths, InstanceChannel.Decode(InstanceChannel.Encode(paths)));
    }

    [Fact]
    public void NoPathsIsAnEmptyListNotAnError()
    {
        Assert.Empty(InstanceChannel.Decode(InstanceChannel.Encode([]))!);
        Assert.Empty(InstanceChannel.Decode("[]"u8)!);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("{\"files\":[\"a.pdf\"]}")]
    [InlineData("[1,2]")]
    public void AnythingElseIsNotAMessage(string text)
    {
        Assert.Null(InstanceChannel.Decode(Encoding.UTF8.GetBytes(text)));
    }

    [Fact]
    public void BlankEntriesAreDropped()
    {
        Assert.Equal(["a.pdf"], InstanceChannel.Decode("[\"\", \" \", \"a.pdf\"]"u8));
    }

    [Fact]
    public async Task AMessageSentToTheFirstInstanceArrivesThere()
    {
        string pipe = UniquePipe();
        var received = new TaskCompletionSource<IReadOnlyList<string>>();
        using var channel = new InstanceChannel(paths => received.TrySetResult(paths), pipe);

        Assert.True(InstanceChannel.Send([@"C:\a.pdf", @"C:\b.pdf"], pipe, Patient));

        Assert.Equal([@"C:\a.pdf", @"C:\b.pdf"], await received.Task.WaitAsync(TimeSpan.FromMilliseconds(Patient)));
    }

    [Fact]
    public async Task TheFirstInstanceKeepsListeningAfterAMessage()
    {
        string pipe = UniquePipe();
        var received = new BlockingCollection<IReadOnlyList<string>>();
        using var channel = new InstanceChannel(paths => received.Add(paths), pipe);

        Assert.True(InstanceChannel.Send(["one.pdf"], pipe, Patient));
        Assert.True(InstanceChannel.Send([], pipe, Patient));

        Assert.Equal(["one.pdf"], await Task.Run(() => received.Take()).WaitAsync(TimeSpan.FromMilliseconds(Patient)));
        Assert.Empty(await Task.Run(() => received.Take()).WaitAsync(TimeSpan.FromMilliseconds(Patient)));
    }

    [Fact]
    public void WithNoFirstInstanceTheSendFails()
    {
        Assert.False(InstanceChannel.Send(["a.pdf"], UniquePipe(), timeout: 200));
    }

    [Fact]
    public void TheSecondStartHandsOverWhatTheCommandLineNamed()
    {
        string folder = Path.GetFullPath(Path.GetTempPath());
        string file = Path.Combine(folder, "a.pdf");

        Assert.Equal([file], App.FilesOf([file]));
        Assert.Equal([file], App.FilesOf(["", file]));
        Assert.Empty(App.FilesOf([]));
    }

    [Fact]
    public void AnArgumentThatIsNotAPathIsLeftOut()
    {
        Assert.Equal([@"C:\x\ok.pdf"], App.FilesOf(["a\0b.pdf", @"C:\x\ok.pdf"]));
        Assert.Empty(App.FilesOf(["\0"]));
        Assert.Equal([Path.GetFullPath("rel.pdf")], App.FilesOf(["rel.pdf"]));
    }

    [Fact]
    public void AnAddressStandsForTheFilesInIt()
    {
        string file = Path.Combine(Path.GetTempPath(), "b.pdf");
        string address = "lazypdf://open?file=" + Uri.EscapeDataString(file);

        Assert.Equal([file], App.FilesOf([address]));
    }

    [Fact]
    public void WhenTheFirstArgumentIsAnAddressItIsTheOnlyOneRead()
    {
        string file = Path.Combine(Path.GetTempPath(), "b.pdf");
        string address = "lazypdf://open?file=" + Uri.EscapeDataString(file);

        Assert.Equal([file], App.FilesOf([address, @"C:\extra\injected.pdf"]));
    }
}
