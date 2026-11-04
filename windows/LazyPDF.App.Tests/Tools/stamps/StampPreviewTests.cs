using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using LazyPDF.App.Tools.Stamps;
using LazyPDF.Core;
using Xunit;
using TextBlock = System.Windows.Controls.TextBlock;

namespace LazyPDF.App.Tests;

// The pending stamp as drawn on the page: the words it shows and whether it shows at all.
public sealed class StampPreviewTests
{
    private static readonly Size Page = new(595, 842);
    private static readonly DateTimeOffset Today = new(2026, 11, 4, 9, 0, 0, TimeSpan.Zero);

    private static void OnSta(Action test)
    {
        ExceptionDispatchInfo? error = null;
        var thread = new Thread(() =>
        {
            try
            {
                test();
            }
            catch (Exception e)
            {
                error = ExceptionDispatchInfo.Capture(e);
            }
            finally
            {
                Dispatcher.CurrentDispatcher.InvokeShutdown();
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        error?.Throw();
    }

    private static string Expand(string template) => StampPreview.Expand(template, 3, 12, "B-7", "a.pdf", Today, "yyyy-MM-dd");

    [Fact]
    public void TokensFillInAndUnknownOnesStayAsTyped()
    {
        Assert.Equal("Page 3 of 12", Expand("Page {page} of {pages}"));
        Assert.Equal("a.pdf B-7", Expand("{file} {bates}"));
        Assert.Equal("{nope} and {", Expand("{nope} and {"));
    }

    [Fact]
    public void ABatesTokenWithoutBatesNumbersStaysAsTyped()
    {
        Assert.Equal("{bates}", StampPreview.Expand("{bates}", 3, 12, null, "a.pdf", Today, "yyyy-MM-dd"));
    }

    [Fact]
    public void ADateTakesItsOwnFormatOrTheDefault()
    {
        Assert.Equal("2026-11-04", Expand("{date}"));
        Assert.Equal("04/11/2026", Expand("{date:dd/MM/yyyy}"));
        Assert.Equal("{date:%%q}", Expand("{date:%%q}"));
        Assert.Equal("04.11.2026", StampPreview.Expand("{date:}", 3, 12, null, "a.pdf", Today, "dd.MM.yyyy"));
    }

    [Fact]
    public void AWatermarkIsOneTextOnTheLayer()
    {
        OnSta(() =>
        {
            var draft = new StampDraft(Watermark: new WatermarkSpec { Text = "DRAFT", Rotation = 45 });

            var layer = Assert.IsType<Canvas>(StampPreview.Build(draft, null, 0, 1, 0, Page, "a.pdf", Today));

            var text = Assert.IsType<TextBlock>(Assert.Single(layer.Children));
            Assert.Equal("DRAFT", text.Text);
            Assert.Equal(0.3, text.Opacity);
            Assert.False(layer.IsHitTestVisible);
        });
    }

    [Fact]
    public void ABatesNumberCountsFromTheStartByThePagesStamped()
    {
        OnSta(() =>
        {
            var spec = new HeaderFooterSpec { Footer = new HeaderFooterBand(Right: "{bates}"), Bates = new BatesSpec("ACME-", "", 4, 10) };

            var layer = Assert.IsType<Canvas>(StampPreview.Build(new StampDraft(HeaderFooter: spec), null, 5, 8, 2, Page, "a.pdf", Today));

            Assert.Equal("ACME-0012", Assert.IsType<TextBlock>(Assert.Single(layer.Children)).Text);
        });
    }

    [Fact]
    public void ASlotThatExpandsToNothingDrawsNothing()
    {
        OnSta(() =>
        {
            var spec = new HeaderFooterSpec { Header = new HeaderFooterBand(Left: "{file}") };

            Assert.Null(StampPreview.Build(new StampDraft(HeaderFooter: spec), null, 0, 1, 0, Page, "", Today));
        });
    }

    [Fact]
    public void ABatesTokenInAPlainHeaderIsDrawnAsTyped()
    {
        OnSta(() =>
        {
            var spec = new HeaderFooterSpec { Header = new HeaderFooterBand(Left: "{bates}") };

            var layer = Assert.IsType<Canvas>(StampPreview.Build(new StampDraft(HeaderFooter: spec), null, 0, 1, 0, Page, "a.pdf", Today));

            Assert.Equal("{bates}", Assert.IsType<TextBlock>(Assert.Single(layer.Children)).Text);
        });
    }

    [Fact]
    public void ABackgroundPictureIsPlacedWhereCoreCentresIt()
    {
        var wide = new Size(200, 100);
        var cover = StampPreview.Fitted(BackgroundFit.Cover, wide.Width, wide.Height, new Size(100, 100));
        Assert.Equal(new Rect(-50, 0, 200, 100), cover);
        var contain = StampPreview.Fitted(BackgroundFit.Contain, wide.Width, wide.Height, new Size(100, 100));
        Assert.Equal(new Rect(0, 25, 100, 50), contain);
        var stretch = StampPreview.Fitted(BackgroundFit.Stretch, wide.Width, wide.Height, new Size(100, 100));
        Assert.Equal(new Rect(0, 0, 100, 100), stretch);
    }

    [Fact]
    public void ABackgroundWithoutAColourOrPictureDrawsNothing()
    {
        OnSta(() =>
        {
            Assert.Null(StampPreview.Build(new StampDraft(Background: new BackgroundSpec()), null, 0, 1, 0, Page, "a.pdf", Today));
        });
    }
}
