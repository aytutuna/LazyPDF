using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Services;
using Xunit;

namespace LazyPDF.App.Tests;

[Collection("Application")]
public sealed class TextDirectionTests
{
    [Theory]
    [InlineData("שלום עולם", true)]
    [InlineData("مرحبا", true)]
    [InlineData("  123 مرحبا", true)]
    [InlineData("Hello שלום", false)]
    [InlineData("Merhaba dünya", false)]
    [InlineData("123", false)]
    [InlineData("", false)]
    public void TheFirstStrongLetterSetsTheDirection(string text, bool rightToLeft) =>
        Assert.Equal(rightToLeft, TextDirection.IsRightToLeft(text));

    [Fact]
    public Task AFollowingBoxFlipsWithItsText() => Sta.Run(() =>
    {
        var box = new TextBox();
        TextDirection.SetFollows(box, true);
        Assert.Equal(FlowDirection.LeftToRight, box.FlowDirection);
        box.Text = "مرحبا";
        Assert.Equal(FlowDirection.RightToLeft, box.FlowDirection);
        box.Text = "Merhaba";
        Assert.Equal(FlowDirection.LeftToRight, box.FlowDirection);
        return Task.CompletedTask;
    });
}
