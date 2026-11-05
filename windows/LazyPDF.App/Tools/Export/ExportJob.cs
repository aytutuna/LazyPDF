using System.Diagnostics;
using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Export;

public static class ExportJob
{
    public static async Task RunAsync(DocumentTab tab, IToolHost host, IImageCodec codec, ExportOptions options, string target)
    {
        var source = Exporter.Source(tab, codec);
        ExportResult? result = null;
        try
        {
            await host.RunBusyAsync(Loc.T("Exporting"), token => Task.Run(() =>
            {
                using var drawn = options.Format == ExportFormat.Pictures ? Exporter.Snapshot(source) : null;
                result = Exporter.Write(drawn is null ? source : source with { Renderer = drawn }, options, target, token);
            }, token));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or PdfReadException)
        {
            host.ShowProblem(ExportProblems.Failed(e, Leaf(target)));
            return;
        }
        if (result is null) return;

        if (result.Files == 0)
        {
            if (result.Gap == ExportGap.NoText) host.ShowNotice(Loc.T("No text found"), Loc.T("This file has no text to export. Run Make searchable first, or save the pages as pictures."));
            else if (options.Format == ExportFormat.Images) host.ShowNotice(Loc.T("No pictures found"), Loc.T("This file has no pictures to save."));
            else host.ShowProblem(new Problem(Loc.T("Nothing exported"), Loc.T("Windows cannot draw these pages. Try another format.")));
            return;
        }

        string text = result.Files == 1 && !options.ToFolder
            ? Loc.T("Saved as {0}.", Path.GetFileName(result.Where))
            : Loc.Plural(result.Files, "Saved {0} file in {1}.", "Saved {0} files in {1}.", Leaf(result.Where));
        if (result.Skipped > 0) text += " " + Loc.Plural(result.Skipped, "{0} page could not be drawn.", "{0} pages could not be drawn.");
        if (result.Gap == ExportGap.OutsideTables) text += " " + Loc.T("Text outside the tables was left out.");
        else if (result.Gap == ExportGap.PastSheetLimit) text += " " + Loc.T("Pages past the first 1000 sheets were left out.");
        host.ShowNotice(Loc.T("Exported"), text, new NoticeAction(Loc.T("Show in folder"), () => Reveal(result.Where, options.ToFolder)));
        host.SetStatus(Loc.T("Export saved."));
    }

    // A drive root has no file name; the root is what the folder is called then.
    internal static string Leaf(string path) => Path.GetFileName(path.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : path;

    private static void Reveal(string path, bool folder)
    {
        var start = new ProcessStartInfo("explorer.exe");
        start.ArgumentList.Add(folder ? path : "/select," + path);
        Process.Start(start);
    }
}
