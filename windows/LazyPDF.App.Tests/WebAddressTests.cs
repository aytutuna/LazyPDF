using System.Reflection;
using LazyPDF.App.Viewer;
using Xunit;

namespace LazyPDF.App.Tests;

public sealed class WebAddressTests
{
    private static string WebAddress(string address) =>
        (string)typeof(PageViewer).GetMethod("WebAddress", BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, [address])!;

    [Theory]
    [InlineData("www.a.org", "https://www.a.org")]
    [InlineData("WWW.a.org", "https://WWW.a.org")]
    [InlineData("https://a.org", "https://a.org")]
    [InlineData("mailto:x@y.z", "mailto:x@y.z")]
    [InlineData("  www.a.org ", "https://www.a.org")]
    public void Adds_https_to_a_bare_www_address(string given, string expected) => Assert.Equal(expected, WebAddress(given));
}
