using System.Globalization;
using System.Text;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// What the open dialog and the drop target hand over: a PDF as it is, a picture or a text file made into a PDF.
public sealed class DocumentOpenerTests
{
    private static readonly DocumentOpener Opener = new(new FakeCodec(), new FakeFonts());

    [Fact]
    public void APdfIsReadAsItIsAndKeepsItsPath()
    {
        using var dir = new TempDir();
        byte[] bytes = Pdfs.Text();
        string path = dir.File("a.pdf", bytes);

        var source = Opener.Read(path);

        Assert.Equal(bytes, source.Bytes);
        Assert.Equal(path, source.Path);
        Assert.Equal("a.pdf", source.Title);
        Assert.False(source.Made);
    }

    [Theory]
    [InlineData("scan.jpg")]
    [InlineData("scan.PNG")]
    [InlineData("scan.tif")]
    [InlineData("scan.heic")]
    public void APictureBecomesAPdfWithNoFileOfItsOwn(string name)
    {
        using var dir = new TempDir();
        string path = dir.File(name, [1, 2, 3, 4]);

        var source = Opener.Read(path);

        Assert.True(source.Made);
        Assert.Null(source.Path);
        Assert.Equal(Path.GetFileNameWithoutExtension(name) + ".pdf", source.Title);
        Assert.Single(PdfDocument.Open(source.Bytes).Pages);
    }

    [Fact]
    public void APictureNoCodecCanReadIsSaidInWords()
    {
        using var dir = new TempDir();
        string path = dir.File("empty.png", []);

        var error = Assert.Throws<InvalidDataException>(() => Opener.Read(path));

        Assert.Equal(ExportText.NoUsablePicture, error.Message);
    }

    [Fact]
    public void ATextFileBecomesPagesOfText()
    {
        using var dir = new TempDir();
        string text = string.Join("\f", ["first page", "second page"]);
        string path = dir.File("notes.txt", Encoding.UTF8.GetBytes(text));

        var source = Opener.Read(path);

        Assert.True(source.Made);
        Assert.Equal("notes.pdf", source.Title);
        Assert.Equal(2, PdfDocument.Open(source.Bytes).Pages.Count);
    }

    [Fact]
    public void TextInAnOldCodePageIsStillRead()
    {
        using var dir = new TempDir();
        string path = dir.File("old.txt", Encoding.Latin1.GetBytes("café"));

        var source = Opener.Read(path);

        Assert.Single(PdfDocument.Open(source.Bytes).Pages);
    }

    [Fact]
    public void Utf16TextWithABomIsDecoded()
    {
        byte[] bytes = [.. Encoding.Unicode.GetPreamble(), .. Encoding.Unicode.GetBytes("héllo")];

        Assert.Equal("héllo", DocumentOpener.Decode(bytes));
    }

    [Fact]
    public void Utf8TextLosesItsBom()
    {
        byte[] bytes = [.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes("héllo")];

        Assert.Equal("héllo", DocumentOpener.Decode(bytes));
    }

    [Fact]
    public void AsciiIsUnchanged()
    {
        Assert.Equal("plain text", DocumentOpener.Decode(Encoding.ASCII.GetBytes("plain text")));
    }

    [Fact]
    public void TurkishCodePageTextIsReadOnATurkishCulture()
    {
        byte[] bytes = Encoding.GetEncoding(1254).GetBytes("şğİ");
        var saved = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo("tr-TR");
        try { Assert.Equal("şğİ", DocumentOpener.Decode(bytes)); }
        finally { CultureInfo.CurrentCulture = saved; }
    }

    [Fact]
    public void TurkishTextNeedsAFontFromTheSource()
    {
        using var dir = new TempDir();
        string path = dir.File("tr.txt", Encoding.UTF8.GetBytes("Çalışma ğ ş ı İ"));

        Assert.Throws<InvalidOperationException>(() => Opener.Read(path));
        var source = new DocumentOpener(new FakeCodec(), new SystemFontSource()).Read(path);

        Assert.Single(PdfDocument.Open(source.Bytes).Pages);
    }

    [Fact]
    public void AFileLongerThanAnArrayCanBeIsRefusedBeforeItIsRead()
    {
        using var dir = new TempDir();
        string path = dir.File("huge.pdf", []);
        using (var stream = new FileStream(path, FileMode.Open)) stream.SetLength(int.MaxValue + 1L);

        var error = Assert.Throws<PdfReadException>(() => Opener.Read(path));

        Assert.Equal(PdfReadProblem.Unsupported, error.Problem);
        Assert.Equal(DocumentOpener.TooLarge, error.Message);
    }

    [Fact]
    public void AMissingFileThrowsFileNotFound()
    {
        using var dir = new TempDir();
        Directory.CreateDirectory(dir.Path);

        Assert.Throws<FileNotFoundException>(() => Opener.Read(dir.Sub("none.pdf")));
    }
}
