using System.Runtime.InteropServices;

namespace LazyPDF.App.Services;

/// <summary>
/// Whether the app runs from an MSIX package (the Store build). The manifest then registers the Open with entries and
/// the lazypdf: address, Windows keeps the user's AppData writes in the package's own store, and the app files are
/// read-only.
/// </summary>
internal static class Packaging
{
    private const int ErrorInsufficientBuffer = 122;

    /// <summary>Settable so a test can stand in for the packaged app; nothing else changes it.</summary>
    internal static bool IsPackaged { get; set; } = Query();

    /// <summary>
    /// GetCurrentPackageFullName with no buffer: a packaged process answers that the buffer is too small, an
    /// unpackaged one that it has no package (APPMODEL_ERROR_NO_PACKAGE).
    /// </summary>
    internal static bool IsPackageResult(int result) => result == ErrorInsufficientBuffer;

    private static bool Query()
    {
        int length = 0;
        return IsPackageResult(GetCurrentPackageFullName(ref length, null));
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(ref int length, char[]? name);
}
