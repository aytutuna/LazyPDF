using System.IO;
using System.Reflection;

namespace LazyPDF.App.Services;

/// <summary>What the About screen shows: the version and copyright from the assembly, the addresses, and the notices file shipped beside the exe.</summary>
internal static class AppInfo
{
    public const string Site = "https://pdf.alazy.app";
    public const string PrivacyPage = "https://pdf.alazy.app/privacy.html";
    public const string SupportAddress = "support@alazy.app";

    public const string NoticesFile = "THIRD-PARTY-NOTICES.txt";

    public static string Version => (typeof(AppInfo).Assembly.GetName().Version ?? new Version(0, 0)).ToString(3);

    public static string Copyright => typeof(AppInfo).Assembly.GetCustomAttribute<AssemblyCopyrightAttribute>()?.Copyright ?? "";

    /// <summary>The notices text; null when the file is not beside the exe.</summary>
    public static string? Notices(string? directory = null)
    {
        try
        {
            return File.ReadAllText(Path.Combine(directory ?? AppContext.BaseDirectory, NoticesFile));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
