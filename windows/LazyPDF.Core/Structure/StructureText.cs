namespace LazyPDF.Core;

// User-visible words of this layer, in one place until Loc.T exists.
public static class StructureText
{
    public static string NewBookmark => "New bookmark";

    public static string UnnamedLayer => "Layer";

    public static string FormKindName(FormKind kind) => kind switch
    {
        FormKind.AcroForm => "Form",
        FormKind.Xfa => "XFA form",
        _ => "None",
    };
}
