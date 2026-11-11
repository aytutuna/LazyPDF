using System.Globalization;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

/// <summary>The changes the accessibility panel makes to a document, kept apart from the controls.</summary>
internal static class AccessibilityEdits
{
    /// <summary>Makes the fix a failed row offers; for the title and language rows, with the text of their box. False when nothing changed.</summary>
    public static bool Apply(PdfDocument document, CheckRow row)
    {
        string value = row.Value.Trim();
        return row.Editor switch
        {
            RowEditor.Title => value.Length > 0 && AccessibilityChecker.Fix(document, AccessibilityFix.SetTitle, value),
            RowEditor.Language => AccessibilityChecker.Fix(document, AccessibilityFix.SetLanguage, value),
            _ => row.Action == RowAction.SetTabOrder && AccessibilityChecker.Fix(document, AccessibilityFix.SetTabOrder),
        };
    }

    /// <summary>What the title box starts with: the file's title, else its name.</summary>
    public static string TitleOf(PdfDocument document, string fileName)
    {
        string title = DocumentMetadata.Read(document).Title ?? "";
        return title.Trim().Length > 0 ? title : Path.GetFileNameWithoutExtension(fileName);
    }

    /// <summary>What the language box starts with: the file's language, else the one Windows speaks.</summary>
    public static string LanguageOf(PdfDocument document)
    {
        string language = PdfText.Read(document, document.Catalog, "Lang") ?? "";
        return language.Length > 0 ? language : CultureInfo.CurrentUICulture.Name;
    }

    /// <summary>Whether tags can be added: the file has neither the tagged mark nor a tree, which is what the tagger needs.</summary>
    public static bool CanAddTags(PdfDocument document) => !document.IsTagged && document.Dict(document.Catalog, "StructTreeRoot") is null;

    /// <summary>True when the figure found by number is gone or no longer has the description the list was built from.</summary>
    internal static bool FigureChanged(StructElement? figure, string listedAlt) => figure is null || (figure.Alt?.Trim() ?? "") != listedAlt;

    /// <summary>Writes the description of a figure; an empty one removes it.</summary>
    public static void SetAlt(PdfDocument document, StructureTree tree, StructElement figure, string text)
    {
        string alt = text.Trim();
        figure.Alt = alt.Length > 0 ? alt : null;
        tree.Write(document);
    }
}
