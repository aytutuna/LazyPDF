using LazyPDF.App.Documents;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Create;

internal static class CreateProblems
{
    public static Problem Failed(Exception error, CreateSource source) => error switch
    {
        PdfReadException { Problem: PdfReadProblem.Damaged } => new(Loc.T("Word file cannot be read"), Loc.T("The file is damaged or is not a Word document. Pick a .docx file.")),
        PdfReadException => new(Loc.T("Word file is not supported"), Loc.T("Only .docx files up to 100 MB can be made into a PDF. Older .doc files must be saved as .docx first.")),
        IOException when source == CreateSource.Word => new(Loc.T("Word file cannot be read"), Loc.T("The file could not be read. Close any program that has it open and try again.")),
        UnauthorizedAccessException when source == CreateSource.Word => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read the file. Check who may open it.")),
        WebViewMissingException => new(Loc.T("Web pages need WebView2"), Loc.T("Lazy PDF draws web pages with the Microsoft Edge WebView2 Runtime, and this computer does not have it. Install it from Microsoft, then try again.")),
        IOException when source == CreateSource.WebPage => new(Loc.T("Web page cannot be drawn"), Loc.T("The web page could not be loaded or drawn. Close any program that has it open and try again.")),
        UnauthorizedAccessException when source == CreateSource.WebPage => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read the web page. Check who may open it.")),
        InvalidOperationException => new(Loc.T("No font for this text"), Loc.T("No font on this computer can draw the text. Remove the letters it cannot show.")),
        ArgumentException when source == CreateSource.Pictures => new(Loc.T("No picture to use"), Loc.T("None of the pictures could be read. Pick JPEG, PNG, TIFF, BMP, GIF or HEIC files.")),
        ArgumentException => new(Loc.T("Margin is too wide"), Loc.T("The margin leaves no room on the page. Pick a smaller margin.")),
        UnauthorizedAccessException => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read one of the pictures. Check who may open it.")),
        _ => new(Loc.T("Picture cannot be read"), Loc.T("One of the pictures could not be read. Close any program that has it open and try again.")),
    };
}
