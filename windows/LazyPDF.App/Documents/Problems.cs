using LazyPDF.Core;

namespace LazyPDF.App.Documents;

/// <summary>A title that says what is wrong and a sentence that says what to do.</summary>
public sealed record Problem(string Title, string Text);

/// <summary>Turns what the engine and the file system raise into words for the info bar.</summary>
public static class Problems
{
    public static Problem Open(Exception error, string name) => error switch
    {
        PdfReadException { Problem: PdfReadProblem.NotPdf } => new(Loc.T("Not a PDF"), Loc.T("{0} is not a PDF file. Pick a PDF, a picture or a text file.", name)),
        PdfReadException { Problem: PdfReadProblem.Damaged } => new(Loc.T("File is damaged"), Loc.T("{0} cannot be repaired. Try an earlier copy of it.", name)),
        PdfReadException { Problem: PdfReadProblem.Unsupported } => new(Loc.T("Not supported yet"), Loc.T("{0} uses something Lazy PDF cannot read yet.", name)),
        PdfReadException => new(Loc.T("File is locked"), Loc.T("{0} needs a password or certificate that was not given.", name)),
        FileNotFoundException or DirectoryNotFoundException => new(Loc.T("File not found"), Loc.T("{0} is not there any more. It may have been moved or deleted.", name)),
        UnauthorizedAccessException => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read {0}. Check who may open it.", name)),
        IOException => new(Loc.T("File cannot be read"), Loc.T("{0} could not be read. Close any program that has it open and try again.", name)),
        InvalidDataException => new(Loc.T("Nothing to open"), Loc.T("{0} has no picture Lazy PDF can read.", name)),
        InvalidOperationException => new(Loc.T("Nothing to open"), Loc.T("No font on this computer can draw the text of {0}.", name)),
        _ => new(Loc.T("File cannot be opened"), Loc.T("{0} could not be opened.", name)),
    };

    /// <summary>What Core's <see cref="UnauthorizedAccessException"/> means in a tool: the file's own permissions forbid the change.</summary>
    public static Problem Restricted() =>
        new(Loc.T("This file cannot be changed"), Loc.T("Its permissions do not allow it. Open it with the owner password."));

    public static Problem Crashed() =>
        new(Loc.T("Something went wrong"), Loc.T("Lazy PDF could not finish what it was doing. Your changes are still open. Save them, then close and reopen the app."));

    public static Problem Save(Exception error, string name) => error switch
    {
        PdfReadException => new(Loc.T("Not saved"), Loc.T("The new {0} did not read back correctly, so the old one was kept. Your changes are still open.", name)),
        UnauthorizedAccessException => new(Loc.T("Not saved"), Loc.T("Windows does not let Lazy PDF write {0}. Save it under another name or in another folder.", name)),
        _ => new(Loc.T("Not saved"), Loc.T("{0} could not be written. Check that the disk has room and that nothing else has the file open. Your changes are still open.", name)),
    };
}
