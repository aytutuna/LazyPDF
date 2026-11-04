using System.IO.Compression;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class ExportZipTests
{
    [Fact]
    public void TheCheckValueOfTheStandardTestString()
    {
        Assert.Equal(0xCBF43926u, ExportZip.Crc32("123456789"u8));
        Assert.Equal(0xCBF43926u, ExportZip.Crc32("6789"u8, ExportZip.Crc32("12345"u8)));
        Assert.Equal(0u, ExportZip.Crc32([]));
    }

    [Fact]
    public void TextIsDeflatedAndAlreadyPackedDataIsStored()
    {
        byte[] text = System.Text.Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("lazy pdf ", 500)));
        var noise = new byte[2000];
        new Random(4).NextBytes(noise);
        var package = ExportZip.Make([new("a.txt", text), new("b.bin", noise), new("c.txt", [])]);

        using var zip = new ZipArchive(new MemoryStream(package), ZipArchiveMode.Read);
        Assert.Equal(["a.txt", "b.bin", "c.txt"], zip.Entries.Select(e => e.FullName));
        Assert.True(zip.GetEntry("a.txt")!.CompressedLength < text.Length / 4);
        Assert.Equal(2000, zip.GetEntry("b.bin")!.CompressedLength);
        Assert.All(zip.Entries, e => Assert.Equal(new DateTime(1980, 1, 1), e.LastWriteTime.DateTime));

        using var read = new MemoryStream();
        zip.GetEntry("a.txt")!.Open().CopyTo(read);
        Assert.Equal(text, read.ToArray());
    }

    [Fact]
    public void NamesOutsideAsciiAreFlaggedAsUtf8()
    {
        var package = ExportZip.Make([new("ğüş/İ.txt", [1, 2, 3])]);
        using var zip = new ZipArchive(new MemoryStream(package), ZipArchiveMode.Read);
        Assert.Equal("ğüş/İ.txt", zip.Entries.Single().FullName);
    }

    [Fact]
    public void TheSameEntriesGiveTheSameBytes()
    {
        var entries = new[] { new ExportZipEntry("x.xml", System.Text.Encoding.UTF8.GetBytes("<a/>")) };
        Assert.Equal(ExportZip.Make(entries), ExportZip.Make(entries));
    }
}
