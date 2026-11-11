using System.IO;
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
}
