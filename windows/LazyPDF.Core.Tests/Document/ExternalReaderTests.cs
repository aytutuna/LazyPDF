using System.Diagnostics;
using LazyPDF.Core;
using Xunit;

namespace LazyPDF.Core.Tests;

// pypdf as a third reader. Does nothing where Python or pypdf is missing (LAZYPDF_PYTHON names the
// interpreter, "python" is tried otherwise).
public class ExternalReaderTests : IDisposable
{
    private const string Script = """
        import sys, os, warnings, logging
        logging.disable(logging.CRITICAL)
        warnings.filterwarnings("ignore")
        from pypdf import PdfReader
        folder = sys.argv[1]
        for name in sorted(os.listdir(folder)):
            try:
                reader = PdfReader(os.path.join(folder, name), strict=True)
                if reader.is_encrypted:
                    reader.decrypt("")
                print(name, len(reader.pages), reader.metadata.title, reader.pages[1].extract_text().strip())
            except Exception as e:
                print(name, "ERROR", type(e).__name__, e)
        """;

    private readonly string _folder = Directory.CreateTempSubdirectory("lazypdf-pypdf").FullName;

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    private string? Run()
    {
        string python = Environment.GetEnvironmentVariable("LAZYPDF_PYTHON") ?? "python";
        var start = new ProcessStartInfo(python) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, WorkingDirectory = _folder };
        start.ArgumentList.Add("-c");
        start.ArgumentList.Add("import pypdf");
        try
        {
            using var probe = Process.Start(start)!;
            probe.WaitForExit();
            if (probe.ExitCode != 0) return null;
            start.ArgumentList.Clear();
            start.ArgumentList.Add("-c");
            start.ArgumentList.Add(Script);
            start.ArgumentList.Add(_folder);
            using var run = Process.Start(start)!;
            string result = run.StandardOutput.ReadToEnd();
            run.WaitForExit();
            return result;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return null;
        }
    }

    [Fact]
    public void PypdfReadsWhatIsWritten()
    {
        var expected = new Dictionary<string, string>();
        foreach (string kind in SaveFixtures.Kinds)
        {
            var document = PdfDocument.Open(SaveFixtures.Make(kind));
            SaveFixtures.Edit(document, "Edited title");
            File.WriteAllBytes(Path.Combine(_folder, $"{kind}-update.pdf"), document.SaveIncremental());
            expected[$"{kind}-update.pdf"] = "2 Edited title Changed";

            document = PdfDocument.Open(SaveFixtures.Make(kind));
            foreach (bool packed in new[] { false, true })
            {
                string name = $"{kind}-rewrite{(packed ? "-packed" : "")}.pdf";
                File.WriteAllBytes(Path.Combine(_folder, name), document.SaveRewrite(new PdfSaveOptions(packed, document.Security)));
                expected[name] = "2 Original title Page two";
            }
        }

        string? result = Run();
        if (result is null) return;
        var lines = result.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.TrimEnd('\r')).ToList();
        Assert.Equal(expected.Count, lines.Count);
        foreach (var (name, text) in expected) Assert.Contains($"{name} {text}", lines);
    }
}
