using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Threading;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Viewer;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.App.Tests;

// The zoom that follows the window, for every document shown and in every layout, and where a destination lands.
public sealed class PageSurfaceFitTests
{
    private static readonly Size Window = new(800, 600);

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

    private static DocumentTab NewTab(int pages) => new(PdfEditSession.Open(Pdfs.Text(pages)), new WindowsPageRenderer(), null, "a.pdf");

    private static PageSurface Measured(DocumentTab tab)
    {
        var surface = new PageSurface();
        surface.Show(tab);
        surface.Measure(Window);
        surface.Arrange(new Rect(Window));
        return surface;
    }

    [Fact]
    public void ADocumentShownAfterTheFirstOpensFittedAtOnce()
    {
        OnSta(() =>
        {
            var surface = Measured(NewTab(2));

            surface.Show(NewTab(3));

            Assert.Equal(FitMode.Width, surface.Fit);
            Assert.Equal(ZoomMath.FitWidth(surface.PageSize(0).Width, Window), surface.Zoom, 3);
        });
    }

    [Fact]
    public void ATabThatWasFittedStaysFittedWhenItComesBack()
    {
        OnSta(() =>
        {
            var first = NewTab(2);
            var surface = Measured(first);
            surface.SetFit(FitMode.Page);
            first.Fit = surface.Fit;
            first.Zoom = 0;

            surface.Show(NewTab(1));
            surface.Show(first);

            Assert.Equal(FitMode.Page, surface.Fit);
        });
    }

    [Fact]
    public void TwoPagesSideBySideFitTheWidthWithNoSideScroll()
    {
        OnSta(() =>
        {
            var surface = Measured(NewTab(4));

            surface.SetArrangement(2, false, true);

            Assert.True(surface.Layout.Extent.Width <= Window.Width + 0.5, $"{surface.Layout.Extent.Width} wide in {Window.Width}");
        });
    }

    [Fact]
    public void FitPageFollowsThePageOfAPagedLayoutThatIsTurnedTo()
    {
        OnSta(() =>
        {
            var surface = Measured(NewTab(3));
            surface.SetArrangement(1, false, false);
            surface.SetFit(FitMode.Page);
            double before = surface.Zoom;

            surface.GoToPage(2);

            Assert.Equal(FitMode.Page, surface.Fit);
            Assert.Equal(before, surface.Zoom, 6);
        });
    }

    [Fact]
    public void ADestinationInARotatedViewIsPlacedByBothOfItsCoordinates()
    {
        OnSta(() =>
        {
            var surface = Measured(NewTab(6));
            surface.SetZoom(1);
            surface.SetRotation(270);

            surface.GoToPage(3, new Point(0, 100));
            double left = surface.ViewRect.Top;
            surface.GoToPage(3, new Point(300, 100));
            double right = surface.ViewRect.Top;

            Assert.NotEqual(left, right);
            Assert.InRange(left, surface.Layout.PageRect(3).Top - 1, surface.Layout.PageRect(3).Bottom);
        });
    }

    [Fact]
    public void AnUprightDestinationPutsItsHeightAtTheTopOfTheView()
    {
        OnSta(() =>
        {
            var surface = Measured(NewTab(6));
            surface.SetZoom(1);

            surface.GoToPage(2, new Point(0, 150));

            double expected = surface.Layout.PageRect(2).Top + 150 * PageSpace.DipPerPoint;
            Assert.Equal(expected, surface.ViewRect.Top, 0);
        });
    }
}
