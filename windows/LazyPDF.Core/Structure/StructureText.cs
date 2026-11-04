namespace LazyPDF.Core;

public static class StructureText
{
    public static string NewBookmark => Loc.T("New bookmark");

    public static string UnnamedLayer => Loc.T("Layer");

    public static string FormKindName(FormKind kind) => kind switch
    {
        FormKind.AcroForm => Loc.T("Form"),
        FormKind.Xfa => Loc.T("XFA form"),
        _ => Loc.T("None"),
    };
}
