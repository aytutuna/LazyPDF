using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

public class SafeSaveTests : IDisposable
{
    private readonly string _folder = Directory.CreateTempSubdirectory("lazypdf-save").FullName;

    public void Dispose()
    {
        foreach (string file in Directory.GetFiles(_folder)) File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(_folder, recursive: true);
    }

    [Fact]
    public void NewFileIsWrittenWithoutLeavingATemporaryOne()
    {
        string path = Path.Combine(_folder, "new.pdf");
        byte[] bytes = SaveFixtures.Table();
        PdfFileSaver.Save(path, bytes);
        Assert.Equal(bytes, File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFileSystemEntries(_folder));
        Assert.False(File.GetAttributes(path).HasFlag(FileAttributes.Hidden));
    }

    [Fact]
    public void ExistingFileIsReplacedAndKeepsItsAttributes()
    {
        string path = Path.Combine(_folder, "old.pdf");
        File.WriteAllBytes(path, TestPdf.Simple());
        File.SetAttributes(path, FileAttributes.Hidden);
        var created = new DateTime(2020, 5, 17, 10, 0, 0, DateTimeKind.Utc);
        File.SetCreationTimeUtc(path, created);

        byte[] bytes = SaveFixtures.Table();
        PdfFileSaver.Save(path, bytes);
        Assert.Equal(bytes, File.ReadAllBytes(path));
        Assert.True(File.GetAttributes(path).HasFlag(FileAttributes.Hidden));
        Assert.Equal(created, File.GetCreationTimeUtc(path));
        Assert.Equal([path], Directory.GetFileSystemEntries(_folder));
    }

    [Fact]
    public void BytesThatAreNotAPdfLeaveTheOriginalAndNoTemporaryFile()
    {
        string path = Path.Combine(_folder, "keep.pdf");
        byte[] original = SaveFixtures.Table();
        File.WriteAllBytes(path, original);
        Assert.Throws<PdfReadException>(() => PdfFileSaver.Save(path, "not a pdf at all"u8.ToArray()));
        Assert.Equal(original, File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFileSystemEntries(_folder));
    }

    [Fact]
    public void ReadOnlyFileIsNotReplaced()
    {
        string path = Path.Combine(_folder, "locked.pdf");
        byte[] original = TestPdf.Simple();
        File.WriteAllBytes(path, original);
        File.SetAttributes(path, FileAttributes.ReadOnly);
        Assert.ThrowsAny<Exception>(() => PdfFileSaver.Save(path, SaveFixtures.Table()));
        Assert.Equal(original, File.ReadAllBytes(path));
        Assert.Single(Directory.GetFileSystemEntries(_folder));
    }

    [Fact]
    public void FileOpenForReadingElsewhereIsNotReplacedAndNothingIsLost()
    {
        string path = Path.Combine(_folder, "busy.pdf");
        byte[] original = TestPdf.Simple();
        File.WriteAllBytes(path, original);
        using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            Assert.ThrowsAny<IOException>(() => PdfFileSaver.Save(path, SaveFixtures.Table()));
        }
        Assert.Equal(original, File.ReadAllBytes(path));
        Assert.Single(Directory.GetFileSystemEntries(_folder));
    }

    [Fact]
    public void EncryptedBytesNeedThePasswordToBeChecked()
    {
        var security = PdfSecurity.Create("pw", "owner", PdfPermissions.All, PdfCryptStrength.Aes256, SaveFixtures.FileId);
        byte[] bytes = PdfDocument.Open(SaveFixtures.Table()).SaveRewrite(new PdfSaveOptions(Security: security));
        string path = Path.Combine(_folder, "enc.pdf");
        Assert.Throws<PdfReadException>(() => PdfFileSaver.Save(path, bytes));
        Assert.False(File.Exists(path));
        PdfFileSaver.Save(path, bytes, "pw");
        Assert.Equal(bytes, File.ReadAllBytes(path));
    }

    [Fact]
    public void AFileThatOnlyOpensByRebuildingIsNotWrittenOverTheOriginal()
    {
        string path = Path.Combine(_folder, "keep.pdf");
        byte[] original = SaveFixtures.Table();
        File.WriteAllBytes(path, original);
        byte[] cut = original[..(TestPdf.Text(original).IndexOf("4 0 obj", StringComparison.Ordinal) + 10)];
        Assert.True(PdfDocument.Open(cut).XrefRebuilt);

        Assert.Throws<PdfReadException>(() => PdfFileSaver.Save(path, cut, null, PdfDocument.Open(original), samePages: false));
        Assert.Equal(original, File.ReadAllBytes(path));
        Assert.Equal([path], Directory.GetFileSystemEntries(_folder));
    }

    [Fact]
    public void ALosingOfPagesIsCaughtWhenThePageCountMustHold()
    {
        string path = Path.Combine(_folder, "pages.pdf");
        byte[] two = TestPdf.Simple(2);
        File.WriteAllBytes(path, two);
        var source = PdfDocument.Open(two);

        Assert.Throws<PdfReadException>(() => PdfFileSaver.Save(path, TestPdf.Simple(1), null, source, samePages: true));
        Assert.Equal(two, File.ReadAllBytes(path));
        PdfFileSaver.Save(path, TestPdf.Simple(1), null, source, samePages: false);
        Assert.Single(PdfDocument.Open(path).Pages);
    }
}
