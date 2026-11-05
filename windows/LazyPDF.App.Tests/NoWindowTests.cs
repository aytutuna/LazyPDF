using System.Windows;
using Xunit;

namespace LazyPDF.App.Tests;

// The tests build panels and views without a window; nothing may open one on the desktop of whoever runs them.
[Collection("Application")]
public sealed class NoWindowTests
{
    [Fact]
    public Task TheApplicationOfTheTestsHasNoWindow() => Sta.Run(() =>
    {
        Assert.Empty(Application.Current.Windows);
        Assert.Null(Application.Current.MainWindow);
        return Task.CompletedTask;
    });

    [Fact]
    public Task TheApplicationOfTheTestsLeavesTheRunningOneAlone() => Sta.Run(() =>
    {
        Assert.True(App.Unattended);
        Assert.Empty(App.StartupFiles);
        return Task.CompletedTask;
    });
}
