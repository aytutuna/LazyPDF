// From Lazy Print's FileAssociation.cs.
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using Microsoft.Win32;

namespace LazyPDF.App.Services;

/// <summary>
/// Puts Lazy PDF in the Open with list for PDFs and opens <c>lazypdf:</c> addresses
/// (<see cref="LazyPdfAddress"/>). Only for the current user (HKCU\Software\Classes, never HKLM), only
/// when the user asks in the settings, and never as the default program: the .pdf key's own value and
/// the user's choice are not touched.
/// </summary>
public static class FileAssociation
{
    public const string ProgId = "LazyPDF.Document";
    private const string ExeName = "LazyPDF.exe";

    /// <summary>The keys under Software\Classes and the value each gets (name "" is the default value), for the app at <paramref name="exePath"/>.</summary>
    public static IReadOnlyList<(string Key, string Name, string Value)> Entries(string exePath) =>
    [
        (LazyPdfAddress.Scheme, "", "URL:Lazy PDF"),
        (LazyPdfAddress.Scheme, "URL Protocol", ""),
        (LazyPdfAddress.Scheme + @"\DefaultIcon", "", $"\"{exePath}\",0"),
        (LazyPdfAddress.Scheme + @"\shell\open\command", "", $"\"{exePath}\" \"%1\""),
        (ProgId, "", "PDF document"),
        (ProgId + @"\DefaultIcon", "", $"\"{exePath}\",0"),
        (ProgId + @"\shell\open\command", "", $"\"{exePath}\" \"%1\""),
        (@"Applications\" + ExeName, "FriendlyAppName", "Lazy PDF"),
        (@"Applications\" + ExeName + @"\shell\open\command", "", $"\"{exePath}\" \"%1\""),
        (@"Applications\" + ExeName + @"\SupportedTypes", ".pdf", ""),
        (@".pdf\OpenWithProgids", ProgId, ""),
    ];

    /// <summary>Writes <see cref="Entries"/> under <paramref name="classes"/>; true when anything changed.</summary>
    public static bool Register(RegistryKey classes, string exePath)
    {
        bool changed = false;
        foreach (var (name, valueName, value) in Entries(exePath))
        {
            using var key = classes.CreateSubKey(name);
            if (key.GetValue(valueName) as string == value) continue;
            key.SetValue(valueName, value);
            changed = true;
        }
        return changed;
    }

    /// <summary>Takes <see cref="Entries"/> out again; true when anything was there.</summary>
    public static bool Unregister(RegistryKey classes)
    {
        bool changed = false;
        foreach (string key in new[] { LazyPdfAddress.Scheme, ProgId, @"Applications\" + ExeName })
        {
            if (classes.OpenSubKey(key) is not { } found) continue;
            found.Dispose();
            classes.DeleteSubKeyTree(key);
            changed = true;
        }
        using var progIds = classes.OpenSubKey(@".pdf\OpenWithProgids", writable: true);
        if (progIds?.GetValue(ProgId) is not null)
        {
            progIds.DeleteValue(ProgId);
            changed = true;
        }
        return changed;
    }

    public static bool IsRegistered(RegistryKey classes)
    {
        using var command = classes.OpenSubKey(@"Applications\" + ExeName + @"\shell\open\command");
        using var progIds = classes.OpenSubKey(@".pdf\OpenWithProgids");
        return command?.GetValue("") is string && progIds?.GetValue(ProgId) is not null;
    }

    public static bool IsRegisteredForCurrentUser()
    {
        using var classes = Registry.CurrentUser.OpenSubKey(@"Software\Classes");
        return classes is not null && IsRegistered(classes);
    }

    /// <summary>
    /// Registers (or removes) the running exe for the current user and tells File Explorer so its icons
    /// follow. False when a policy keeps the user's classes read-only.
    /// </summary>
    public static bool SetForCurrentUser(bool on)
    {
        if (Environment.ProcessPath is not { } exe) return false;
        try
        {
            using var classes = Registry.CurrentUser.CreateSubKey(@"Software\Classes");
            if (on ? Register(classes, exe) : Unregister(classes)) SHChangeNotify(ShcneAssocChanged, ShcnfIdList, IntPtr.Zero, IntPtr.Zero);
            return true;
        }
        catch (Exception e) when (e is UnauthorizedAccessException or SecurityException or IOException)
        {
            return false;
        }
    }

    private const int ShcneAssocChanged = 0x08000000;
    private const uint ShcnfIdList = 0x0000;

    [DllImport("shell32.dll", ExactSpelling = true)]
    private static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
}
