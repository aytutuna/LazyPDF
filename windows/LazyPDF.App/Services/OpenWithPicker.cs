using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace LazyPDF.App.Services;

/// <summary>The system's Open With list for a file. It names the default app, which may be Lazy PDF, so the person chooses.</summary>
internal static class OpenWithPicker
{
    private const uint Exec = 0x4;
    private const int Cancelled = unchecked((int)0x800704C7);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct OpenAsInfo
    {
        public string File;
        public string? Class;
        public uint Flags;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHOpenWithDialog(IntPtr owner, in OpenAsInfo info);

    /// <summary>False when the dialog could not be shown; a person closing it is not a failure.</summary>
    public static bool Show(string path, Window? ownerWindow)
    {
        var info = new OpenAsInfo { File = path, Class = null, Flags = Exec };
        var owner = ownerWindow is null ? IntPtr.Zero : new WindowInteropHelper(ownerWindow).Handle;
        int result = SHOpenWithDialog(owner, in info);
        return result >= 0 || result == Cancelled;
    }
}
