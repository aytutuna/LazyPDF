using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Export;

internal static class ExportProblems
{
    public static Problem Failed(Exception error, string name) => error switch
    {
        PdfReadException => new(Loc.T("Too large to export"), Loc.T("{0} is too big for this format. Export fewer pages or pick another format.", name)),
        UnauthorizedAccessException => new(Loc.T("Not exported"), Loc.T("Windows does not let Lazy PDF write to {0}. Pick another folder.", name)),
        _ => new(Loc.T("Not exported"), Loc.T("{0} could not be written. Check that the disk has room and that nothing else has the file open.", name)),
    };
}
