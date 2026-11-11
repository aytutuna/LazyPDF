using LazyPDF.App.Tools.FillSign;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// Signatures kept for reuse: one PNG each, newest first, signatures apart from initials.
public sealed class SavedSignaturesTests
{
    private static PdfRgbaImage Image(byte shade) =>
        new(2, 1, [shade, 0, 0, 255, 0, shade, 0, 128]);

    [Fact]
    public void NothingIsSavedBeforeTheFirstOne()
    {
        using var dir = new TempDir();

        Assert.Empty(new SavedSignatures(dir.Sub("none")).List(SavedKind.Signature));
    }

    [Fact]
    public void ASavedSignatureComesBackWithItsPixels()
    {
        OnSta.Run(() =>
        {
            using var dir = new TempDir();
            var saved = new SavedSignatures(dir.Sub("sigs"));

            var item = saved.Add(SavedKind.Signature, Image(200));
            var back = saved.Load(item)!;

            Assert.Equal(2, back.Width);
            Assert.Equal(200, back.Rgba[0]);
            Assert.Equal(128, back.Rgba[7]);
        });
    }

    [Fact]
    public void SignaturesAndInitialsAreKeptApartNewestFirst()
    {
        OnSta.Run(() =>
        {
            using var dir = new TempDir();
            var saved = new SavedSignatures(dir.Sub("sigs"));
            var first = saved.Add(SavedKind.Signature, Image(1));
            Thread.Sleep(5);
            var second = saved.Add(SavedKind.Signature, Image(2));
            var initials = saved.Add(SavedKind.Initials, Image(3));

            Assert.Equal([second, first], saved.List(SavedKind.Signature));
            Assert.Equal([initials], saved.List(SavedKind.Initials));
        });
    }

    [Fact]
    public void StampPicturesAreKeptApartFromSignatures()
    {
        OnSta.Run(() =>
        {
            using var dir = new TempDir();
            var saved = new SavedSignatures(dir.Sub("stamps"));
            var picture = saved.Add(SavedKind.Stamp, Image(7));
            saved.Add(SavedKind.Signature, Image(8));

            Assert.Equal([picture], saved.List(SavedKind.Stamp));
            Assert.Equal(7, saved.Load(picture)!.Rgba[0]);

            saved.Remove(picture);

            Assert.Empty(saved.List(SavedKind.Stamp));
        });
    }

    [Fact]
    public void ARemovedSignatureIsGone()
    {
        OnSta.Run(() =>
        {
            using var dir = new TempDir();
            var saved = new SavedSignatures(dir.Sub("sigs"));
            var item = saved.Add(SavedKind.Initials, Image(9));

            saved.Remove(item);

            Assert.Empty(saved.List(SavedKind.Initials));
            Assert.Null(saved.Load(item));
        });
    }
}
