using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The installed fonts as files Core can embed. Arial is on every Windows.
public sealed class SystemFontSourceTests
{
    private static readonly SystemFontSource Source = new();

    private static bool IsFontFile(byte[] data) =>
        data.Length > 4 && (data.AsSpan(0, 4).SequenceEqual(new byte[] { 0, 1, 0, 0 }) || data.AsSpan(0, 4).SequenceEqual("true"u8)
                            || data.AsSpan(0, 4).SequenceEqual("ttcf"u8) || data.AsSpan(0, 4).SequenceEqual("OTTO"u8));

    [Fact]
    public void AnInstalledFamilyGivesItsFontFile()
    {
        var file = Source.Find("Arial", FontStyles.Regular);

        Assert.NotNull(file);
        Assert.True(IsFontFile(file.Data));
    }

    [Fact]
    public void TheBoldFaceIsAnotherFile()
    {
        var regular = Source.Find("Arial", FontStyles.Regular)!;
        var bold = Source.Find("Arial", FontStyles.Bold)!;

        Assert.NotEqual(regular.Data.Length, bold.Data.Length);
    }

    [Fact]
    public void AFamilyThatIsNotThereGivesNull() =>
        Assert.Null(Source.Find("No Such Family Anywhere", FontStyles.Regular));

    [Fact]
    public void ThePdfNamesForTheCommonFamiliesAreFound()
    {
        Assert.NotNull(Source.Find("Helvetica", FontStyles.Regular));
        Assert.NotNull(Source.Find("times new roman", FontStyles.Regular));
    }

    [Fact]
    public void TheFileIsOneCoreCanEmbedForTurkishLetters()
    {
        var document = PdfDocument.Open(Pdfs.Text());
        var font = new PdfFontEmbedder(document, Source).Add("Arial", FontStyles.Regular, ["Çalışma ğ ş ı İ"]);

        Assert.NotNull(font);
    }
}
