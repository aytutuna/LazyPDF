using System.Runtime.InteropServices;
using System.Windows;
using LazyPDF.App.Services;
using LazyPDF.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace LazyPDF.App.Tools.Create;

/// <summary>Draws a web page file to PDF in a web view nobody sees. It must run on the window thread.</summary>
internal static class WebPagePdf
{
    private static readonly TimeSpan LoadLimit = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan PrintLimit = TimeSpan.FromMinutes(5);

    public static async Task<byte[]> RenderAsync(string file, PdfPageSetup setup, CancellationToken cancel)
    {
        var layout = WebPageRules.Layout(setup);
        file = Path.GetFullPath(file);
        string folder = Path.GetDirectoryName(file)!;

        // Off screen rather than hidden: a web view that is never shown does not lay the page out.
        var view = new WebView2();
        var host = new Window
        {
            Content = view, WindowStyle = WindowStyle.None, ShowInTaskbar = false, ShowActivated = false,
            Left = -32000, Top = -32000, Width = 1024, Height = 768,
        };
        host.Show();
        // The web view calls cannot be cancelled, so each is waited on with the token; closing the window in finally stops what is left.
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        limit.CancelAfter(LoadLimit);
        try
        {
            var environment = await CoreWebView2Environment.CreateAsync(null, AppFolders.WebView).WaitAsync(limit.Token);
            await view.EnsureCoreWebView2Async(environment).WaitAsync(limit.Token);
            var core = view.CoreWebView2;
            core.Settings.IsScriptEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsWebMessageEnabled = false;
            core.Settings.IsPasswordAutosaveEnabled = false;
            core.Settings.IsGeneralAutofillEnabled = false;

            core.SetVirtualHostNameToFolderMapping(WebPageRules.Host, folder, CoreWebView2HostResourceAccessKind.Deny);
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            core.WebResourceRequested += (_, e) =>
            {
                if (!WebPageRules.IsAllowed(e.Request.Uri)) e.Response = environment.CreateWebResourceResponse(null, 403, "Blocked", "");
            };
            core.NavigationStarting += (_, e) =>
            {
                if (!WebPageRules.IsAllowed(e.Uri)) e.Cancel = true;
            };
            core.FrameNavigationStarting += (_, e) =>
            {
                if (!WebPageRules.IsAllowed(e.Uri)) e.Cancel = true;
            };

            var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            core.NavigationCompleted += (_, e) => loaded.TrySetResult(e.IsSuccess);
            core.Navigate(WebPageRules.PageAddress(file));
            if (!await loaded.Task.WaitAsync(limit.Token)) throw new IOException("The page did not load.");

            var settings = environment.CreatePrintSettings();
            settings.Orientation = CoreWebView2PrintOrientation.Portrait;
            settings.PageWidth = layout.Width;
            settings.PageHeight = layout.Height;
            settings.MarginTop = settings.MarginBottom = settings.MarginLeft = settings.MarginRight = layout.Margin;
            settings.ShouldPrintBackgrounds = true;
            settings.ShouldPrintHeaderAndFooter = false;
            limit.CancelAfter(PrintLimit);
            using var stream = await core.PrintToPdfStreamAsync(settings).WaitAsync(limit.Token);
            using var bytes = new MemoryStream();
            await stream.CopyToAsync(bytes, cancel);
            return bytes.ToArray();
        }
        catch (WebView2RuntimeNotFoundException)
        {
            throw new WebViewMissingException();
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested)
        {
            throw new IOException("The page took too long.");
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or ArgumentException)
        {
            throw new IOException("The web view could not draw the page.", e);
        }
        finally
        {
            host.Close();
            view.Dispose();
        }
    }
}
