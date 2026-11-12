using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Shell;

namespace LazyPDF.App.Services;

/// <summary>The taskbar jump list: Windows keeps the recent files, this only reports them.</summary>
public static class JumpLists
{
    public static void Install()
    {
        if (Application.Current is null || App.Unattended)
            return;
        JumpList.SetJumpList(Application.Current, new JumpList { ShowRecentCategory = true, ShowFrequentCategory = false });
    }

    public static void Note(string path)
    {
        if (Application.Current is null || App.Unattended || !File.Exists(path))
            return;
        JumpList.AddToRecentCategory(path);
    }

    /// <summary>Takes one file out of the jump list's recent category.</summary>
    public static void Forget(string path)
    {
        if (Application.Current is null || App.Unattended)
            return;
        try
        {
            var id = typeof(IShellItem).GUID;
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref id, out var item);
            Destinations().RemoveDestination(item);
        }
        catch (Exception e) when (e is COMException or ArgumentException)
        {
            // The file is gone or Windows has no entry for it: nothing to remove.
        }
    }

    /// <summary>Empties the jump list's recent category; other programs' recent files stay.</summary>
    public static void ForgetAll()
    {
        if (Application.Current is null || App.Unattended)
            return;
        try { Destinations().RemoveAllDestinations(); }
        catch (COMException) { }
    }

    private static IApplicationDestinations Destinations() =>
        (IApplicationDestinations)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("86C14003-4D6B-4EF3-A7B4-0506663B2E68"))!)!;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
    }

    [ComImport, Guid("12337D35-94C6-48A0-BCE7-6A9C69D4D600"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationDestinations
    {
        void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string appId);
        void RemoveDestination([MarshalAs(UnmanagedType.Interface)] object item);
        void RemoveAllDestinations();
    }
}
