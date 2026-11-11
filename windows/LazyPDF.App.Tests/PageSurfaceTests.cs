using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The scrolling pages without a window: zoom around a point, going to a page, the layouts, and a reload that keeps the place.
public sealed class PageSurfaceTests
{
    private static readonly Size Window = new(800, 600);

    // WPF elements belong to one thread; each test gets one of its own.
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

    private static (PageSurface Surface, DocumentTab Tab) Open(int pages)
    {
        var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(pages)), new WindowsPageRenderer(), null, "a.pdf");
        var surface = new PageSurface();
        surface.Show(tab);
        surface.Measure(Window);
        surface.Arrange(new Rect(Window));
        return (surface, tab);
    }

    [Fact]
    public void ATabComesBackWithItsRotationAndPlace()
    {
        OnSta(() =>
        {
            var (surface, a) = Open(4);
            surface.SetRotation(90);
            surface.GoToPage(2);
            var place = surface.TopPlace();
            int rotation = surface.Rotation;

            var b = new DocumentTab(PdfEditSession.Open(Pdfs.Text(2)), new WindowsPageRenderer(), null, "b.pdf");
            surface.Show(b);
            Assert.Equal(0, surface.Rotation);

            surface.Show(a, rotation);
            surface.GoToPage(place!.Value.Page, place.Value.Point);
            Assert.Equal(90, surface.Rotation);
            Assert.Equal(place, surface.TopPlace());
        });
    }

    [Theory]
    [InlineData(0, 1.57, 1)]
    [InlineData(0, 1.25, 1.25)]
    [InlineData(0, 2.5, 1.5)]
    [InlineData(90, 1.57, 1)]
    [InlineData(90, 1.25, 1.25)]
    [InlineData(90, 2.5, 1.5)]
    [InlineData(90, 1.57, 1.5)]
    [InlineData(0, 1.57, 1.25)]
    public void TilesMeetOnTheSameDevicePixelEdge(int rotation, double zoom, double dpi)
    {
        OnSta(() =>
        {
            var (surface, _) = Open(3);
            VisualTreeHelper.SetRootDpi(surface, new DpiScale(dpi, dpi));
            surface.SetRotation(rotation);
            surface.SetZoom(zoom);
            double ppp = surface.Zoom * PageSpace.DipPerPoint * dpi;
            for (int page = 0; page < 3; page++)
            {
                var size = surface.PageSize(page);
                var matrix = surface.PageMatrix(page)!.Value;
                var area = new Rect(0, 0, size.Width * ppp, size.Height * ppp);
                var tiles = TilePlan.Cover(page, 0, PageTint.None, size, ppp, area, WindowsPageRenderer.Reachable);
                var snapped = new Dictionary<(int, int), Rect>();
                var pixels = new Dictionary<(int, int), int>();
                foreach (var tile in tiles)
                {
                    var bitmap = BitmapSource.Create(tile.Width, tile.Height, 96, 96, PixelFormats.Gray8, null, new byte[tile.Width * tile.Height], tile.Width);
                    snapped[(tile.Key.Column, tile.Key.Row)] = PageSurface.SnapRect(PageSurface.Destination(tile.Key, bitmap, matrix, size), dpi);
                    pixels[(tile.Key.Column, tile.Key.Row)] = tile.Width;
                }

                int columns = tiles.Max(t => t.Key.Column) + 1, rows = tiles.Max(t => t.Key.Row) + 1;
                for (int row = 0; row < rows; row++)
                {
                    for (int column = 0; column < columns; column++)
                    {
                        var a = snapped[(column, row)];
                        if (column + 1 < columns)
                        {
                            var b = snapped[(column + 1, row)];
                            if (rotation == 0) Assert.Equal(a.Right, b.Left, 6);
                            else Assert.Equal(a.Bottom, b.Top, 6);
                            double across = rotation == 0 ? a.Width : a.Height;
                            Assert.Equal(pixels[(column, row)], Math.Round(across * dpi));
                        }
                        if (row + 1 < rows)
                        {
                            var b = snapped[(column, row + 1)];
                            if (rotation == 0) Assert.Equal(a.Bottom, b.Top, 6);
                            else Assert.Equal(b.Right, a.Left, 6);
                        }
                    }
                }
            }
        });
    }

    [Fact]
    public void AFileOpensFittedToTheWidth()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(3);

            double expected = ZoomMath.FitWidth(surface.PageSize(0).Width, Window);
            Assert.Equal(FitMode.Width, surface.Fit);
            Assert.Equal(expected, surface.Zoom, 6);
            Assert.Equal(3, surface.PageCount);
            Assert.Equal(0, surface.CurrentPage);
        });
    }

    [Fact]
    public void TheTabRemembersTheZoomAndThePage()
    {
        OnSta(() =>
        {
            var (surface, tab) = Open(5);

            surface.GoToPage(3);
            surface.SetZoom(1.5);

            Assert.Equal(3, tab.PageIndex);
            Assert.Equal(1.5, surface.Zoom);
            Assert.Equal(FitMode.None, surface.Fit);
        });
    }

    [Fact]
    public void GoingBackKeepsTheColumnWhenZoomedIn()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(4);
            surface.SetZoom(3);
            surface.SetHorizontalOffset(surface.HorizontalOffset + 150);
            double offset = surface.HorizontalOffset;
            var place = surface.TopPlace()!.Value;

            surface.GoToPage(0);
            surface.GoToPage(place.Page, place.Point, keepX: true);

            Assert.Equal(offset, surface.HorizontalOffset, 3);
        });
    }

    [Fact]
    public void GoingToAPageScrollsItsTopIntoView()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(5);

            surface.GoToPage(3);

            Assert.Equal(3, surface.CurrentPage);
            Assert.Equal(surface.Layout.PageRect(3).Top - ViewLayout.Margin, surface.VerticalOffset, 0);
        });
    }

    [Fact]
    public void ScrollingByHandChangesThePageInView()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(5);
            int raised = 0;
            surface.PageChanged += (_, _) => raised++;

            surface.GoToPage(1);
            surface.ScrollBy(0, surface.Layout.PageRect(2).Top - surface.VerticalOffset - 50);

            Assert.Equal(2, surface.CurrentPage);
            Assert.True(raised >= 2);
        });
    }

    [Fact]
    public void ZoomingKeepsThePointUnderThePointerWhereItWas()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(4);
            surface.GoToPage(1);
            var pointer = new Point(420, 300);
            var (page, spot) = surface.Hit(pointer, nearest: true)!.Value;

            surface.SetZoom(surface.Zoom * 2, pointer);

            var after = surface.PageMatrix(page)!.Value.Transform(spot);
            Assert.Equal(pointer.X, after.X, 0);
            Assert.Equal(pointer.Y, after.Y, 0);
        });
    }

    [Fact]
    public void TheZoomStaysBetweenTheLimits()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(1);
            var (min, max) = surface.ZoomLimits;

            surface.SetZoom(1000);
            Assert.Equal(max, surface.Zoom);
            surface.SetZoom(0.0001);
            Assert.Equal(min, surface.Zoom);
        });
    }

    [Theory]
    [InlineData(0)]
    [InlineData(90)]
    [InlineData(180)]
    [InlineData(270)]
    public void APointOnARotatedPageComesBackAsThePageSpaceItWas(int rotation)
    {
        OnSta(() =>
        {
            var (surface, _) = Open(2);
            surface.SetRotation(rotation);
            surface.SetZoom(1);
            var size = surface.PageSize(0);
            var spot = new Point(size.Width * 0.25, size.Height * 0.75);

            var onScreen = surface.PageMatrix(0)!.Value.Transform(spot);
            var hit = surface.Hit(onScreen);

            Assert.Equal(0, hit!.Value.Page);
            Assert.Equal(spot.X, hit.Value.Point.X, 3);
            Assert.Equal(spot.Y, hit.Value.Point.Y, 3);
        });
    }

    [Fact]
    public void ARotationSwapsTheShapeOfThePageOnTheScreen()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(1);
            surface.SetZoom(1);
            var upright = surface.Layout.PageRect(0).Size;

            surface.SetRotation(90);

            var turned = surface.Layout.PageRect(0).Size;
            Assert.Equal(upright.Width, turned.Height, 0);
            Assert.Equal(upright.Height, turned.Width, 0);
            Assert.Equal(90, surface.Rotation);
        });
    }

    [Fact]
    public void OnePageAtATimeLaysOutOnlyThatPageAndTurnsItAtTheEdge()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(5);
            surface.SetArrangement(1, false, continuous: false);

            surface.GoToPage(2);
            Assert.True(surface.Layout.Contains(2));
            Assert.False(surface.Layout.Contains(1));

            surface.SetZoom(2);
            surface.ScrollBy(0, 1_000_000);
            surface.ScrollBy(0, 100);

            Assert.Equal(3, surface.CurrentPage);
            Assert.True(surface.Layout.Contains(3));
            Assert.Equal(0, surface.VerticalOffset);
        });
    }

    [Fact]
    public void WheelNotchesTurnOnePageEach()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(5);
            surface.SetArrangement(1, false, continuous: false);
            surface.SetFit(FitMode.Page);

            for (int i = 0; i < 3; i++) surface.ScrollBy(0, 120, smooth: false);

            Assert.Equal(3, surface.CurrentPage);
        });
    }

    [Fact]
    public void SmoothWheelEventsInARowTurnOnePage()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(5);
            surface.SetArrangement(1, false, continuous: false);
            surface.SetFit(FitMode.Page);

            for (int i = 0; i < 5; i++) surface.ScrollBy(0, 30, smooth: true);

            Assert.Equal(1, surface.CurrentPage);
        });
    }

    [Fact]
    public void ANotchUpAtTheTopLandsAtTheBottomOfThePageBefore()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(5);
            surface.SetArrangement(1, false, continuous: false);
            surface.SetZoom(2);
            surface.GoToPage(2);

            surface.ScrollBy(0, -120, smooth: false);

            Assert.Equal(1, surface.CurrentPage);
            Assert.True(surface.VerticalOffset > 0);
        });
    }

    [Fact]
    public void ScrollsOtherThanTheWheelTurnEveryTime()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(5);
            surface.SetArrangement(1, false, continuous: false);
            surface.GoToPage(1);
            surface.SetZoom(2);

            for (int i = 0; i < 4; i++) surface.ScrollBy(0, 1_000_000);

            Assert.Equal(3, surface.CurrentPage);
        });
    }

    [Fact]
    public void FacingPagesWithACoverGoByTheirSpreads()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(6);
            surface.SetArrangement(2, cover: true, continuous: true);

            surface.GoToPage(2);

            Assert.Equal(2, surface.CurrentPage);
            Assert.Equal(surface.Layout.PageRect(1).Top, surface.Layout.PageRect(2).Top);
            Assert.True(surface.Layout.PageRect(0).Bottom < surface.Layout.PageRect(1).Top);
        });
    }

    [Fact]
    public void AReloadKeepsTheScrollPositionOnWhatWasInView()
    {
        OnSta(() =>
        {
            var (surface, tab) = Open(6);
            surface.SetZoom(1);
            surface.GoToPage(3);
            surface.ScrollBy(0, 120);
            double offset = surface.VerticalOffset;

            Pdfs.Retitle(tab.Session, "Edited");
            tab.Commit("Title");
            surface.Reload();

            Assert.Equal(3, surface.CurrentPage);
            Assert.Equal(offset, surface.VerticalOffset, 0);
        });
    }

    [Fact]
    public void AReloadGivesNewPicturesOnlyToThePagesTheEditTouched()
    {
        OnSta(() =>
        {
            var (surface, tab) = Open(4);
            surface.SetZoom(0.1);
            var before = Enumerable.Range(0, 4).Select(surface.VersionOf).ToArray();

            new PdfAnnotationWriter(tab.Document).AddNote(tab.Document.Pages[1], new PdfRect(100, 100, 120, 120), new AnnotationInfo("Ada", "Look", null, DateTimeOffset.UnixEpoch));
            tab.Commit("Note");
            surface.Reload();

            var after = Enumerable.Range(0, 4).Select(surface.VersionOf).ToArray();
            Assert.Equal(before[0], after[0]);
            Assert.NotEqual(before[1], after[1]);
            Assert.Equal(before[2], after[2]);
            Assert.Equal(before[3], after[3]);
        });
    }

    [Fact]
    public void AReloadAfterAFileRewriteGivesEveryPageNewPictures()
    {
        OnSta(() =>
        {
            var (surface, tab) = Open(3);
            surface.SetZoom(0.1);
            var before = Enumerable.Range(0, 3).Select(surface.VersionOf).ToArray();

            using var dir = new TempDir();
            tab.SaveCompact(dir.File("compact.pdf", []));
            surface.Reload();

            Assert.All(Enumerable.Range(0, 3), page => Assert.NotEqual(before[page], surface.VersionOf(page)));
        });
    }

    [Fact]
    public void AReloadAfterPagesWereDeletedStaysInsideTheFile()
    {
        OnSta(() =>
        {
            var (surface, tab) = Open(5);
            surface.GoToPage(4);

            PageOperations.Delete(tab.Document, [3, 4]);
            tab.Commit("Delete pages");
            surface.Reload();

            Assert.Equal(3, surface.PageCount);
            Assert.InRange(surface.CurrentPage, 0, 2);
        });
    }

    [Fact]
    public void AnOverlayIsKeptForThePageAndAttachedOnlyWhileItIsNear()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(8);
            surface.SetZoom(1);
            var overlay = surface.Overlay(0);

            Assert.Same(overlay, surface.Overlay(0));
            Assert.Equal(new Size(surface.PageSize(0).Width, surface.PageSize(0).Height), new Size(overlay.Width, overlay.Height));
            Assert.Contains(overlay, surface.Children.Cast<UIElement>());

            surface.GoToPage(7);

            Assert.DoesNotContain(overlay, surface.Children.Cast<UIElement>());
            Assert.Same(overlay, surface.Overlay(0));
        });
    }

    [Fact]
    public void AnOverlayDoesNotClipWhatTouchesThePageEdge()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(2);
            surface.SetZoom(1);
            var overlay = surface.Overlay(0);
            var mark = new System.Windows.Shapes.Rectangle { Width = 10, Height = 10 };
            System.Windows.Controls.Canvas.SetLeft(mark, -5);
            overlay.Children.Add(mark);

            surface.Measure(Window);
            surface.Arrange(new Rect(Window));

            Assert.False(overlay.ClipToBounds);
            Assert.Contains(mark, overlay.Children.Cast<UIElement>());
        });
    }

    [Fact]
    public void AFileTheSystemCannotDrawStillHasItsPagesLaidOut()
    {
        OnSta(() =>
        {
            var tab = new DocumentTab(PdfEditSession.Open(Pdfs.Text(3)), new FakeRenderer { Draws = false }, null, "a.pdf");
            var surface = new PageSurface();

            surface.Show(tab);
            surface.Measure(Window);
            surface.Arrange(new Rect(Window));

            Assert.Equal(3, surface.PageCount);
            Assert.True(surface.PageSize(0).Width > 100);
            Assert.True(surface.Layout.Contains(0));
        });
    }

    [Fact]
    public void BetweenPagesThereIsNoHitUnlessTheNearestIsAsked()
    {
        OnSta(() =>
        {
            var (surface, _) = Open(3);
            surface.SetZoom(1);
            var rect = surface.Layout.PageRect(0);
            var gap = new Point(rect.Left + 10, rect.Bottom + 2 - surface.VerticalOffset);

            Assert.Null(surface.Hit(gap));
            Assert.Equal(0, surface.Hit(gap, nearest: true)!.Value.Page);
        });
    }
}
