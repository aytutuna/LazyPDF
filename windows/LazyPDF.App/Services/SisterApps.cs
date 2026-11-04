using System.Diagnostics;
using Microsoft.Win32;

namespace LazyPDF.App.Services;

/// <summary>
/// Finds Lazy Scan and Lazy Print by the addresses they register for the current user. A running Lazy Print is
/// handed the file over its pipe, the way a second start of it would; one that is installed but not running is
/// started with a <c>lazyprint:open?file=</c> address; with neither the caller prints itself.
/// </summary>
public sealed class SisterApps : ISisterApps
{
    private const string PrintScheme = "lazyprint";
    private const string ScanScheme = "lazyscan";

    private static readonly string PrintPipe = $"LazyPrint.Open.{Process.GetCurrentProcess().SessionId}";

    public bool LazyScanInstalled => HasScheme(ScanScheme);

    public void OpenLazyScan()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(ScanScheme + ":") { UseShellExecute = true });
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
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

    private static bool HasScheme(string scheme)
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
}
