namespace LazyPDF.Core;

/// <summary>The few words the export writes into its files and that a person may read.</summary>
public static class ExportText
{
    public static string Page(int number) => Loc.T("Page {0}", number);
    public static string Image(int number) => Loc.T("Picture {0}", number);
    public static string Table(int number, int page) => Loc.T("Table {0} (p{1})", number, page);
    public static string Slide(int number) => Loc.T("Slide {0}", number);

    public static string NoUsablePicture => Loc.T("None of the pictures could be read.");
    public static string TooLarge => Loc.T("The file is too large to export.");
    public static string PicturesLeftOut(int count) =>
        Loc.Plural(count, "{0} picture was left out because the file is too large.", "{0} pictures were left out because the file is too large.");

    public static string NoFont => Loc.T("No font file can draw this text.");
}
