using System.Diagnostics;
using System.Runtime.CompilerServices;
using LazyPDF.App.Services;

namespace LazyPDF.App.Tests;

// The test host is not the app, so the decode child is the built app dll run through dotnet.
internal static class JpxTestHost
{
    [ModuleInitializer]
    internal static void Init()
    {
        string? host = Process.GetCurrentProcess().MainModule?.FileName;
        if (!string.Equals(Path.GetFileNameWithoutExtension(host), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            host = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet";
        }
        JpxWorker.CommandLine = [host!, Path.Combine(AppContext.BaseDirectory, "LazyPDF.dll"), JpxChild.Switch];
    }
}
