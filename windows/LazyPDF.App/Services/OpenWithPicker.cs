using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace LazyPDF.App.Services;

/// <summary>The system's Open With list for a file. It names the default app, which may be Lazy PDF, so the person chooses.</summary>
internal static class OpenWithPicker
{
    private const uint Exec = 0x4;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct OpenAsInfo
    {
        public string File;
        public string? Class;
        public uint Flags;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHOpenWithDialog(IntPtr owner, ref OpenAsInfo info);

    public static void Show(string path)
    {
        var info = new OpenAsInfo { File = path, Class = null, Flags = Exec };
        var owner = Application.Current?.MainWindow is { } window ? new WindowInteropHelper(window).Handle : IntPtr.Zero;
        SHOpenWithDialog(owner, ref info);
    }
}
