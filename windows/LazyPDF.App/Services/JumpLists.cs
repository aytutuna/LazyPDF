using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
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
        Remove(path);
    }

    internal static void Remove(string path)
    {
        try
        {
            var id = typeof(IShellItem).GUID;
            object item;
            if (File.Exists(path) || Directory.Exists(path))
                SHCreateItemFromParsingName(path, null, ref id, out item);
            else
                SHCreateItemFromParsingName(path, MissingFile(), ref id, out item);
            Destinations().RemoveDestination(item);
        }
        catch (Exception e) when (e is COMException or IOException or UnauthorizedAccessException or ArgumentException)
        {
            // Windows has no entry for it or cannot name it: the entry stays.
        }
    }

    // A moved or deleted file cannot be bound by path alone; a bind context that supplies its data lets the shell name it anyway.
    private static IBindCtx MissingFile()
    {
        CreateBindCtx(0, out var context);
        var data = new FindData();
        data.Set(new Win32FindData { FileAttributes = 0x80 });
        context.RegisterObjectParam("File System Bind Data", data);
        return context;
    }

    [DllImport("ole32.dll", PreserveSig = false)]
    private static extern void CreateBindCtx(int reserved, out IBindCtx context);

    [StructLayout(LayoutKind.Sequential, Pack = 4, CharSet = CharSet.Unicode)]
    private struct Win32FindData
    {
        public uint FileAttributes;
        public long CreationTime, LastAccessTime, LastWriteTime;
        public uint SizeHigh, SizeLow, Reserved0, Reserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string FileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AlternateFileName;
    }

    [ComImport, Guid("01E18D10-4D8B-11D2-855D-006008059367"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileSystemBindData
    {
        void SetFindData(ref Win32FindData data);
        void GetFindData(out Win32FindData data);
    }

    private sealed class FindData : IFileSystemBindData
    {
        private Win32FindData _data;
        public void Set(Win32FindData data) => _data = data;
        public void SetFindData(ref Win32FindData data) => _data = data;
        public void GetFindData(out Win32FindData data) => data = _data;
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
    private static extern void SHCreateItemFromParsingName(string path, IBindCtx? context, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);

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
