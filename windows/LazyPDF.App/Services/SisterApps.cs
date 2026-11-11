using System.Diagnostics;
using Microsoft.Win32;
using Windows.System;

namespace LazyPDF.App.Services;

/// <summary>
/// Finds Lazy Scan and Lazy Print by the addresses they register, for the current user or by their Store package. A running Lazy Print is
/// handed the file over its pipe, the way a second start of it would; one that is installed but not running is
/// started with a <c>lazyprint:open?file=</c> address; with neither the caller prints itself.
/// </summary>
public sealed class SisterApps : ISisterApps
{
    private const string PrintScheme = "lazyprint";
    private const string ScanScheme = "lazyscan";

    private static readonly string PrintPipe = $"LazyPrint.Open.{Process.GetCurrentProcess().SessionId}";

    private (DateTime At, bool Found) _scan, _print;

    // Asked of Windows when the classes key has no entry, which takes a moment, and the Home tab and the toolbar ask often.
    public bool LazyScanInstalled => Cached(ref _scan, ScanScheme);

    public bool LazyPrintInstalled => Cached(ref _print, PrintScheme);

    private static bool Cached(ref (DateTime At, bool Found) slot, string scheme)
    {
        if (DateTime.UtcNow - slot.At > TimeSpan.FromSeconds(30)) slot = (DateTime.UtcNow, HasScheme(scheme));
        return slot.Found;
    }

    public bool OpenLazyScan()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(ScanScheme + ":") { UseShellExecute = true });
            return true;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    public bool TryPrint(string path)
    {
        if (InstanceChannel.Send([path], PrintPipe, timeout: 300)) return true;
        if (!HasScheme(PrintScheme)) return false;
        try
        {
            using var process = Process.Start(new ProcessStartInfo($"{PrintScheme}:open?file={Uri.EscapeDataString(path)}") { UseShellExecute = true });
            return true;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return false;
        }
    }

    // An app from the Store registers its address in its package, not under the classes key, so a miss there is asked of Windows.
    private static bool HasScheme(string scheme) => InClasses(scheme) || Handled(scheme);

    private static bool InClasses(string scheme)
    {
        try
        {
            using var key = Registry.ClassesRoot.OpenSubKey(scheme);
            return key is not null;
        }
        catch (Exception e) when (e is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    internal static bool Handled(string scheme)
    {
        try
        {
            var status = Launcher.QueryUriSupportAsync(new Uri(scheme + ":"), LaunchQuerySupportType.Uri).AsTask().GetAwaiter().GetResult();
            return status == LaunchQuerySupportStatus.Available;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or UriFormatException)
        {
            return false;
        }
    }
}
