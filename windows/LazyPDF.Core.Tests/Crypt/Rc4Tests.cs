using System.Text;
using Xunit;

namespace LazyPDF.Core.Tests;

public class Rc4Tests
{
    [Theory]
    [InlineData("Key", "Plaintext", "BBF316E8D940AF0AD3")]
    [InlineData("Wiki", "pedia", "1021BF0420")]
    [InlineData("Secret", "Attack at dawn", "45A01F645FC35B383552544B9BF5")]
    public void MatchesPublishedVectors(string key, string text, string expected)
    {
        byte[] output = Rc4.Apply(Encoding.ASCII.GetBytes(key), Encoding.ASCII.GetBytes(text));

        Assert.Equal(expected, Convert.ToHexString(output));
    }

    [Fact]
    public void AppliedTwiceGivesTheInput()
    {
        byte[] key = [1, 2, 3, 4, 5];
        byte[] data = new byte[1000];
        new Random(2).NextBytes(data);

        Assert.Equal(data, Rc4.Apply(key, Rc4.Apply(key, data)));
    }

    [Fact]
    public void KeyLongerThan256BytesWorks()
    {
        byte[] key = new byte[300];
        new Random(4).NextBytes(key);

        Assert.Equal(10, Rc4.Apply(key, new byte[10]).Length);
    }
}
