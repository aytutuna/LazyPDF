using LazyPDF.App.Tools.Protect;
using Xunit;

namespace LazyPDF.App.Tests.Tools.Protect;

public sealed class PasswordStrengthTests
{
    [Theory]
    [InlineData("", Strength.None)]
    [InlineData("aaaaaaaaaaaaaaaa", Strength.Weak)]
    [InlineData("password1", Strength.Weak)]
    [InlineData("abcdefgh", Strength.Weak)]
    [InlineData("12345678901234567890", Strength.Weak)]
    [InlineData("passwordpassword1234", Strength.Weak)]
    [InlineData("Tr0ub4dor&3", Strength.Fair)]
    [InlineData("Tr0ub4dor&3x", Strength.Good)]
    [InlineData("correct horse battery staple", Strength.Strong)]
    public void WordsAreRatedByLengthAndVariety(string password, Strength expected) =>
        Assert.Equal(expected, PasswordStrength.Rate(password));

    [Theory]
    [InlineData("", false)]
    [InlineData("a", true)]
    [InlineData("12345", true)]
    [InlineData("123456", false)]
    public void OnlyAPasswordUnderSixIsVeryShort(string password, bool expected) =>
        Assert.Equal(expected, PasswordStrength.VeryShort(password));

    [Fact]
    public void ALongerWordIsNeverRatedBelowItsPrefix()
    {
        const string word = "Zq7!mK2#vX9$pL4@wR8%";
        var rated = Enumerable.Range(1, word.Length).Select(n => PasswordStrength.Rate(word[..n])).ToList();
        Assert.Equal(rated.OrderBy(s => s), rated);
    }

    [Fact]
    public void EveryRatingBeyondNoneHasAHint()
    {
        foreach (var strength in new[] { Strength.Weak, Strength.Fair, Strength.Good, Strength.Strong })
            Assert.NotEmpty(PasswordStrength.Hint(strength));
        Assert.Empty(PasswordStrength.Hint(Strength.None));
    }
}
