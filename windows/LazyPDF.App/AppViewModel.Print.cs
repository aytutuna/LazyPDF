// Printing: Lazy Print gets the file when it is there, otherwise the window opens the Windows print dialog.

using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App;

public sealed partial class AppViewModel
{
    /// <summary>Raised when Lazy Print did not take the document: the window prints it itself.</summary>
    public event EventHandler<DocumentTab>? SystemPrintRequested;

    public void Print()
    {
        if (ActiveDocument is not { } tab) return;
        if (tab.Document.Security is { OpenedAsOwner: false } security && !security.Permissions.HasFlag(PdfPermissions.Print))
        {
            ShowProblem(new Problem(Loc.T("Printing is not allowed"), Loc.T("The owner of {0} did not allow it to be printed.", tab.Title)));
            return;
        }
        string file;
        try
        {
            file = WritePrintCopy(tab);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            ShowProblem(new Problem(Loc.T("Not printed"), Loc.T("A copy of {0} could not be made for printing. Check that the disk has room.", tab.Title)));
            return;
        }
        if (_sisters.TryPrint(file)) SetStatus(Loc.T("Sent to Lazy Print."));
        else SystemPrintRequested?.Invoke(this, tab);
    }

    // The file as it stands now, unsaved changes included, in a folder of its own so the name stays the document's.
    // Lazy Print may read it later, so it is not removed here; what is a day old goes at the next print.
    private string WritePrintCopy(DocumentTab tab)
    {
        if (Directory.Exists(_printDirectory))
        {
            foreach (string old in Directory.EnumerateDirectories(_printDirectory).Where(d => Directory.GetCreationTimeUtc(d) < DateTime.UtcNow.AddDays(-1)))
            {
                try { Directory.Delete(old, recursive: true); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
        }
        string folder = System.IO.Path.Combine(_printDirectory, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        string name = tab.Title.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) ? tab.Title : tab.Title + ".pdf";
        string file = System.IO.Path.Combine(folder, name);
        File.WriteAllBytes(file, tab.Session.Current.ToArray());
        return file;
    }
}
