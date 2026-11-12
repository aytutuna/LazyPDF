using LazyPDF.App.Services;

namespace LazyPDF.App.Tools.Create;

internal static class OfficeNotice
{
    /// <summary>The note under a PDF made from an Office file: it can differ from the program that made the file, and what was left out.</summary>
    public static string Text(MadePdf made, OfficeApp? app)
    {
        var left = (made.Features ?? []).OrderBy(s => s.Kind, StringComparer.Ordinal).Select(s => Name(s.Kind)).ToList();
        if (made.Unreadable > 0) left.Add(Loc.T("letters no font has"));
        string text = app == OfficeApp.Excel ? Loc.T("Layout can differ from Excel.") : Loc.T("Layout can differ from Word.");
        return left.Count == 0 ? text : text + " " + Loc.T("Left out: {0}.", string.Join(", ", left));
    }

    private static string Name(string kind) => kind switch
    {
        "table" => Loc.T("tables too large or nested (shown as paragraphs)"),
        "text-box" => Loc.T("text boxes"),
        "picture" => Loc.T("pictures that could not be read"),
        "chart" => Loc.T("charts"),
        "shape" => Loc.T("shapes"),
        "drawing" => Loc.T("drawings"),
        "footnote" => Loc.T("footnotes"),
        "endnote" => Loc.T("endnotes"),
        "comment" => Loc.T("comment marks"),
        "equation" => Loc.T("equations"),
        "tracked-change" => Loc.T("tracked changes"),
        "field" => Loc.T("fields (shown as last saved)"),
        "floating-picture" => Loc.T("picture positions (placed in line)"),
        "hidden-sheet" => Loc.T("hidden sheets"),
        "chart-sheet" => Loc.T("chart sheets"),
        "other-sheet" => Loc.T("sheets that are not worksheets"),
        "rich-text" => Loc.T("formatting inside cells (first style used)"),
        "fill-pattern" => Loc.T("pattern and gradient fills"),
        "text-rotation" => Loc.T("rotated text (shown straight)"),
        "formula-no-value" => Loc.T("formulas without a saved result (shown empty)"),
        "cell-outside-grid" => Loc.T("cells beyond the sheet limits"),
        "long-text" => Loc.T("text cut at the cell limit"),
        "sheet-picture" => Loc.T("pictures on sheets"),
        "sheet-chart" => Loc.T("charts on sheets"),
        "sheet-shape" => Loc.T("shapes on sheets"),
        "conditional-format" => Loc.T("conditional formatting"),
        "sparkline" => Loc.T("sparklines"),
        "data-validation" => Loc.T("data validation"),
        "sheet-comment" => Loc.T("cell comments"),
        "rtl-text" => Loc.T("right-to-left text direction"),
        "complex-script" => Loc.T("complex-script shaping"),
        "hidden-slide" => Loc.T("hidden slides"),
        "slide-shape" => Loc.T("shapes, pictures and tables on slides"),
        "slide-gradient" => Loc.T("gradient fills (first color used)"),
        "slide-text-cut" => Loc.T("text cut at the size limit"),
        _ => kind,
    };
}
