using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Create;

internal static class CreateProblems
{
    public static Problem Failed(Exception error, CreateRequest request)
    {
        var source = request.Source;
        string? path = source == CreateSource.Office ? request.Files![0] : null;
        var app = path is null ? null : FileKinds.OfficeAppOf(path);
        bool excel = app == OfficeApp.Excel;
        bool slides = app == OfficeApp.PowerPoint;
        return error switch
        {
            WebPageException { Problem: WebPageProblem.TooBig } => new(Loc.T("Page is too big"), Loc.T("The web page file is over 20 MB. Pick a smaller one.")),
            WebPageException { Problem: WebPageProblem.TimedOut } => new(Loc.T("Page took too long"), Loc.T("The web page did not finish loading. Pick a simpler page.")),
            WebPageException => new(Loc.T("Page is too long"), Loc.T("The web page would make more than 2000 pages. Pick a shorter one.")),
            PdfReadException or IOException when source == CreateSource.WebPage => new(Loc.T("Web page cannot be drawn"), Loc.T("The web page could not be loaded or drawn. Close any program that has it open and try again.")),
            PdfReadException when path is not null && FileKinds.IsOldOffice(path) => new(Loc.T("Older Office file is not supported"), Loc.T("Save it as .docx, .xlsx or .pptx first.")),
            PdfReadException { Problem: PdfReadProblem.Damaged } when slides => new(Loc.T("PowerPoint file cannot be read"), Loc.T("The file is damaged or is not a PowerPoint presentation. Pick a .pptx file.")),
            PdfReadException when slides => new(Loc.T("PowerPoint file is not supported"), Loc.T("The presentation cannot be made into a PDF. Only .pptx files up to 100 MB with a slide to show can be; older .ppt files must be saved as .pptx first.")),
            PdfReadException { Problem: PdfReadProblem.Damaged } when excel => new(Loc.T("Excel file cannot be read"), Loc.T("The file is damaged or is not an Excel workbook. Pick an .xlsx file.")),
            PdfReadException when excel => new(Loc.T("Excel file is not supported"), Loc.T("The workbook cannot be made into a PDF. Only .xlsx files up to 100 MB with something to print can be; older .xls and .xlsb files must be saved as .xlsx first.")),
            PdfReadException { Problem: PdfReadProblem.Damaged } when source == CreateSource.Office => new(Loc.T("Word file cannot be read"), Loc.T("The file is damaged or is not a Word document. Pick a .docx file.")),
            PdfReadException when source == CreateSource.Office => new(Loc.T("Word file is not supported"), Loc.T("Only .docx files up to 100 MB can be made into a PDF. Older .doc files must be saved as .docx first.")),
            WebViewMissingException => new(Loc.T("Web pages need WebView2"), Loc.T("Lazy PDF draws web pages with the Microsoft Edge WebView2 Runtime, and this computer does not have it. Install it from Microsoft, then try again.")),
            UnauthorizedAccessException when source == CreateSource.WebPage => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read the web page. Check who may open it.")),
            IOException when source == CreateSource.Office => new(excel ? Loc.T("Excel file cannot be read") : slides ? Loc.T("PowerPoint file cannot be read") : Loc.T("Word file cannot be read"), Loc.T("The file could not be read. Close any program that has it open and try again.")),
            UnauthorizedAccessException when source == CreateSource.Office => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read the file. Check who may open it.")),
            InvalidOperationException => new(Loc.T("No font for this text"), Loc.T("No font on this computer can draw the text. Remove the letters it cannot show.")),
            ArgumentException when source == CreateSource.Pictures => new(Loc.T("No picture to use"), Loc.T("None of the pictures could be read. Pick JPEG, PNG, TIFF, BMP, GIF or HEIC files.")),
            ArgumentException => new(Loc.T("Margin is too wide"), Loc.T("The margin leaves no room on the page. Pick a smaller margin.")),
            UnauthorizedAccessException => new(Loc.T("No access"), Loc.T("Windows does not let Lazy PDF read one of the pictures. Check who may open it.")),
            _ => new(Loc.T("Picture cannot be read"), Loc.T("One of the pictures could not be read. Close any program that has it open and try again.")),
        };
    }
}
