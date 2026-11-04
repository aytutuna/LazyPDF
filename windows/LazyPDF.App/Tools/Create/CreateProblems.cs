using LazyPDF.App.Documents;

namespace LazyPDF.App.Tools.Create;

internal static class CreateProblems
{
    public static Problem Failed(Exception error, CreateSource source) => error switch
    {
        InvalidOperationException => new(Loc.T("No font for this text"), Loc.T("No font on this computer can draw the text. Remove the letters it cannot show.")),
        ArgumentException when source == CreateSource.Pictures => new(Loc.T("No picture to use"), Loc.T("None of the pictures could be read. Pick JPEG, PNG, TIFF, BMP, GIF or HEIC files.")),
        ArgumentException => new(Loc.T("Margin is too wide"), Loc.T("The margin leaves no room on the page. Pick a smaller margin.")),
        UnauthorizedAccessException => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read one of the pictures. Check who may open it.")),
        _ => new(Loc.T("Picture cannot be read"), Loc.T("One of the pictures could not be read. Close any program that has it open and try again.")),
    };
}
