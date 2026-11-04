using LazyPDF.Core;
using Xunit;
using Xunit.Abstractions;

namespace LazyPDF.Core.Tests;

// Reads the form of every file in a list when LAZYPDF_CORPUS names a text file of paths, exports it,
// fills and resets a copy, flattens another and looks for blanks on the first page; does nothing
// otherwise. Only counts are printed.
public class FormCorpusTests(ITestOutputHelper output)
{
    [Fact]
    public void EveryFormReadsFillsExportsAndFlattens()
    {
        string? list = Environment.GetEnvironmentVariable("LAZYPDF_CORPUS");
        if (string.IsNullOrEmpty(list) || !File.Exists(list)) return;

        int files = 0, forms = 0, fields = 0, orphans = 0, xfa = 0, dynamic = 0, scripts = 0, notRun = 0, filled = 0, refused = 0, flattened = 0, burned = 0, detected = 0, detectedFiles = 0;
        var problems = new List<string>();
        foreach (string path in File.ReadAllLines(list).Where(l => l.Trim().Length > 0))
        {
            if (!File.Exists(path)) continue;
            byte[] bytes;
            PdfDocument document;
            try
            {
                bytes = File.ReadAllBytes(path);
                document = PdfDocument.Open(bytes);
            }
            catch (PdfReadException)
            {
                continue;
            }
            files++;
            try
            {
                if (document.Pages.Count > 0)
                {
                    var found = FieldDetector.Detect(document, 0);
                    detected += found.Count;
                    if (found.Count > 0) detectedFiles++;
                }
                var form = PdfForm.Read(document);
                if (form.Xfa != XfaKind.None) xfa++;
                if (form.Xfa == XfaKind.Dynamic) dynamic++;
                if (form.Fields.Count == 0) continue;
                forms++;
                fields += form.Fields.Count;
                orphans += form.Orphans.Count;
                var all = form.Scripts;
                scripts += all.Count;
                notRun += all.Count(s => !s.Ran);
                PdfFdf.Read(PdfFdf.Write(form.ExportFdf()));
                PdfXfdf.Read(PdfXfdf.Write(form.ExportFdf()));
                _ = form.ExportCsv();
                _ = form.TabSequence(0);

                var target = form.Fields.FirstOrDefault(f => f.Kind == FieldKind.Text && !f.Has(FieldFlags.ReadOnly) && f.Widgets.Count > 0 && f.Widgets[0].PageIndex >= 0);
                if (target is not null)
                {
                    try
                    {
                        form.SetValue(target.Name, "Test 123");
                        form.Reset();
                        filled++;
                        using var reopened = PdfDocument.Open(document.SaveIncremental());
                        _ = PdfForm.Read(reopened).Fields.Count;
                    }
                    catch (InvalidOperationException)
                    {
                        refused++;
                    }
                }

                var again = PdfDocument.Open(bytes);
                var flat = PdfForm.Read(again);
                burned += flat.Flatten();
                flattened++;
                PdfDocument.Open(again.SaveRewrite());
            }
            catch (PdfReadException)
            {
            }
            catch (Exception e)
            {
                problems.Add($"{e.GetType().Name}: {e.Message}");
            }
        }
        output.WriteLine($"{files} files, {forms} with fields ({fields} fields, {orphans} orphans), {xfa} XFA ({dynamic} dynamic), {scripts} scripts ({notRun} not run)");
        output.WriteLine($"{filled} filled and reset, {refused} refused for lack of a font, {flattened} flattened ({burned} widgets), {detected} blanks proposed in {detectedFiles} files");
        output.WriteLine($"{problems.Count} problems");
        foreach (string problem in problems.Distinct().Take(10)) output.WriteLine(problem);
        Assert.Empty(problems);
    }
}
