// Form data in and out: FDF, XFDF, CSV and JSON files.

using System.Text.Json;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Forms;

public sealed partial class FormsPanel
{
    private static string DataFilter =>
        Loc.T("FDF files") + "|*.fdf|" + Loc.T("XFDF files") + "|*.xfdf|" + Loc.T("CSV files") + "|*.csv|" + Loc.T("JSON files") + "|*.json";

    private void Export_Click(object sender, RoutedEventArgs e)
    {
        var tab = Tab!;
        var dialog = new SaveFileDialog
        {
            Title = Loc.T("Export form data"),
            Filter = DataFilter,
            FileName = System.IO.Path.GetFileNameWithoutExtension(tab.Title),
        };
        if (dialog.ShowDialog() != true) return;
        string name = System.IO.Path.GetFileName(dialog.FileName);
        try
        {
            var format = FormData.FormatOf(dialog.FileName) ?? (DataFormat)(dialog.FilterIndex - 1);
            File.WriteAllBytes(dialog.FileName, FormData.Export(Form, format, tab.Title));
            Host!.SetStatus(Loc.T("Form data exported."));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Host!.ShowProblem(new Problem(Loc.T("Not exported"), Loc.T("{0} could not be written. Check the folder and try again.", name)));
        }
    }

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        if (Signed(() => Import_Click(sender, e))) return;
        var tab = Tab!;
        var host = Host!;
        var dialog = new OpenFileDialog { Title = Loc.T("Import form data"), Filter = DataFilter };
        if (dialog.ShowDialog() != true) return;
        string name = System.IO.Path.GetFileName(dialog.FileName);
        if (FormData.FormatOf(dialog.FileName) is not { } format)
        {
            host.ShowProblem(new Problem(Loc.T("Unknown data file"), Loc.T("{0} is not an FDF, XFDF, CSV or JSON file. Pick another file.", name)));
            return;
        }
        byte[] data;
        try
        {
            data = File.ReadAllBytes(dialog.FileName);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(new Problem(Loc.T("Data not read"), Loc.T("{0} could not be read. Close any program that has it open and try again.", name)));
            return;
        }
        FormFillResult? result = null;
        int rows = 1;
        _working = true;
        IsEnabled = false;
        try
        {
            await host.RunBusyAsync(Loc.T("Filling in the form"), async token =>
            {
                int used = 1;
                result = await FormEdits.ApplyAsync(tab, _fonts, Loc.T("Import form data"), form => FormData.Import(form, format, data, out used), token);
                rows = used;
            });
        }
        catch (Exception error) when (error is PdfReadException or JsonException or FormatException)
        {
            host.ShowProblem(new Problem(Loc.T("Data not read"), Loc.T("{0} could not be read as form data. Pick a file that a form export wrote.", name)));
            return;
        }
        catch (Exception error) when (error is InvalidOperationException or ArgumentException)
        {
            host.ShowProblem(FormEdits.ProblemOf(error));
            return;
        }
        finally
        {
            _working = false;
            IsEnabled = true;
        }
        if (result is not null) Report(host, result, rows);
    }

    private static void Report(IToolHost host, FormFillResult result, int rows)
    {
        var notes = new List<string>();
        if (result.UnknownFields.Count > 0)
            notes.Add(Loc.Plural(result.UnknownFields.Count, "{0} name matches no field: {1}.", "{0} names match no field: {1}.", string.Join(", ", result.UnknownFields.Take(5))));
        if (result.Rejected.Count > 0)
            notes.Add(Loc.Plural(result.Rejected.Count, "{0} field did not take its value: {1}.", "{0} fields did not take their values: {1}.", string.Join(", ", result.Rejected.Take(5))));
        if (result.NotRun.Count > 0) notes.Add(FormText.ScriptNotRun);
        if (rows > 1) notes.Add(Loc.T("The file has {0} rows. Only the first was used.", rows));
        host.SetStatus(Loc.Plural(result.Filled, "{0} field filled.", "{0} fields filled."));
        if (notes.Count > 0) host.ShowNotice(Loc.T("Some data was not used"), string.Join(" ", notes));
    }
}
