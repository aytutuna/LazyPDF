using LazyPDF.App.Panels.Pages;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// A rebuilt thumbnail list shows the old pictures until the new ones are drawn.
public sealed class PageThumbTests
{
    private static async Task<(PageThumb, WindowsPageRenderer)> Loaded(double width = 100, double height = 140)
    {
        var renderer = new WindowsPageRenderer();
        renderer.Load(PdfEditSession.Open(Pdfs.Text()), null);
        var thumb = new PageThumb(0, "1", width, height, 36, 5, renderer);
        var done = new TaskCompletionSource();
        thumb.PropertyChanged += (_, _) => done.TrySetResult();
        _ = thumb.Image;
        await done.Task.WaitAsync(TimeSpan.FromSeconds(30));
        return (thumb, renderer);
    }

    [Fact]
    public async Task AThumbThatInheritsShowsThePictureAtOnce()
    {
        var (old, renderer) = await Loaded();
        using var _ = renderer;
        Assert.NotNull(old.Image);

        var thumb = new PageThumb(0, "1", 100, 140, 36, 5, null);
        thumb.Inherit(old);

        Assert.Same(old.Image, thumb.Image);
    }

    [Fact]
    public async Task ADifferentSizeInheritsNothing()
    {
        var (old, renderer) = await Loaded();
        using var _ = renderer;

        var thumb = new PageThumb(0, "1", 140, 100, 36, 5, null);
        thumb.Inherit(old);

        Assert.Null(thumb.Image);
    }

    [Fact]
    public async Task ReleaseLetsGoOfTheInheritedPicture()
    {
        var (old, renderer) = await Loaded();
        using var _ = renderer;

        var thumb = new PageThumb(0, "1", 100, 140, 36, 5, null);
        thumb.Inherit(old);
        thumb.Release();

        Assert.Null(thumb.Image);
    }

    [Fact]
    public async Task ADifferentPageInheritsNothing()
    {
        var (old, renderer) = await Loaded();
        using var _ = renderer;

        var thumb = new PageThumb(0, "1", 100, 140, 36, 6, null);
        thumb.Inherit(old);

        Assert.Null(thumb.Image);
    }
}
