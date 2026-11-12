namespace LazyPDF.Core;

public static class AccessibilityText
{
    internal static string AlreadyInTree => Loc.T("The item is already in the tree.");
    internal static string RootNeedsElement => Loc.T("Only an element can sit at the root.");
    internal static string IntoItself => Loc.T("An element cannot go into itself.");
    internal static string TreeTooLarge => Loc.T("The structure tree is too large to edit.");

    public static string Name(AccessibilityRule rule) => rule switch
    {
        AccessibilityRule.Tagged => Loc.T("Document is tagged"),
        AccessibilityRule.Title => Loc.T("Title is set and shown"),
        AccessibilityRule.Language => Loc.T("Language is set"),
        AccessibilityRule.Security => Loc.T("Security allows screen readers"),
        AccessibilityRule.Bookmarks => Loc.T("Long document has bookmarks"),
        AccessibilityRule.Searchable => Loc.T("Pages have text"),
        AccessibilityRule.Encoding => Loc.T("Fonts map to text"),
        AccessibilityRule.TaggedContent => Loc.T("All content is tagged"),
        AccessibilityRule.TabOrder => Loc.T("Tab order follows structure"),
        AccessibilityRule.Contrast => Loc.T("Color contrast"),
        AccessibilityRule.FigureAlt => Loc.T("Figures have alt text"),
        AccessibilityRule.TableStructure => Loc.T("Tables are well formed"),
        AccessibilityRule.TableHeaders => Loc.T("Tables have headers"),
        AccessibilityRule.ListStructure => Loc.T("Lists are well formed"),
        AccessibilityRule.HeadingOrder => Loc.T("Headings are in order"),
        AccessibilityRule.RoleMap => Loc.T("Custom tags are mapped"),
        AccessibilityRule.Links => Loc.T("Links have text"),
        AccessibilityRule.FormNames => Loc.T("Form fields have names and tooltips"),
        AccessibilityRule.FormTagged => Loc.T("Form fields are tagged"),
        _ => rule.ToString(),
    };

    public static string Passed(AccessibilityRule rule) => rule switch
    {
        AccessibilityRule.Tagged => Loc.T("The document is tagged."),
        AccessibilityRule.Title => Loc.T("The title is set and the window shows it."),
        AccessibilityRule.Language => Loc.T("The document language is set."),
        AccessibilityRule.Security => Loc.T("The security settings allow screen readers."),
        AccessibilityRule.Bookmarks => Loc.T("The document has bookmarks, or is short enough not to need them."),
        AccessibilityRule.Searchable => Loc.T("Every page with pictures also has text."),
        AccessibilityRule.Encoding => Loc.T("Every font maps its characters to text."),
        AccessibilityRule.TaggedContent => Loc.T("All page content is tagged or marked as an artifact."),
        AccessibilityRule.TabOrder => Loc.T("Pages with links or fields follow the structure order."),
        AccessibilityRule.FigureAlt => Loc.T("Every figure has alt text, or there are no figures."),
        AccessibilityRule.TableStructure => Loc.T("Every table has rows and cells in the right places, or there are no tables."),
        AccessibilityRule.TableHeaders => Loc.T("Every table has header cells, or there are no tables."),
        AccessibilityRule.ListStructure => Loc.T("Every list has items, labels and bodies in the right places, or there are no lists."),
        AccessibilityRule.HeadingOrder => Loc.T("Headings go down one level at a time, or there are none."),
        AccessibilityRule.RoleMap => Loc.T("Every custom tag maps to a standard one."),
        AccessibilityRule.Links => Loc.T("Every link is tagged and has text."),
        AccessibilityRule.FormNames => Loc.T("Every form field has a name and a tooltip, or there are no fields."),
        AccessibilityRule.FormTagged => Loc.T("Every form field is tagged, or there are no fields."),
        _ => "",
    };

    // {0} is how many places are affected, {1} where the first is.
    public static string Failed(AccessibilityRule rule) => rule switch
    {
        AccessibilityRule.Tagged => Loc.T("The document has no tags. Add tags so a screen reader can read it in order."),
        AccessibilityRule.Title => Loc.T("The document has no title. Give it one so the window and the reader can name it."),
        AccessibilityRule.Language => Loc.T("The document language is missing or not valid. Set it so a screen reader picks the right voice."),
        AccessibilityRule.Security => Loc.T("The security settings stop screen readers from reading the text. Allow text access for accessibility."),
        AccessibilityRule.Bookmarks => Loc.T("The document is long and has no bookmarks. Add bookmarks for its sections."),
        AccessibilityRule.Searchable => Loc.T("Pages with only pictures: {0}{1}. Run text recognition so the words can be read."),
        AccessibilityRule.Encoding => Loc.T("Fonts that give no text: {0}{1}. Create the file again with fonts that map to text."),
        AccessibilityRule.TaggedContent => Loc.T("Pages with content not in the tags: {0}{1}. Tag it or mark it as an artifact."),
        AccessibilityRule.TabOrder => Loc.T("Pages not using structure order: {0}{1}. Set the tab order to follow the structure."),
        AccessibilityRule.FigureAlt => Loc.T("Figures without alt text: {0}{1}. Describe each one."),
        AccessibilityRule.TableStructure => Loc.T("Tables with a broken layout: {0}{1}. Give each table rows of header and data cells, with the same cells in every row."),
        AccessibilityRule.TableHeaders => Loc.T("Tables without header cells: {0}{1}. Mark the header row or column."),
        AccessibilityRule.ListStructure => Loc.T("Lists with items in the wrong place: {0}{1}. Put labels and bodies inside list items."),
        AccessibilityRule.HeadingOrder => Loc.T("Headings out of order: {0}{1}. Start at level 1 and go down one level at a time."),
        AccessibilityRule.RoleMap => Loc.T("Custom tags without a standard meaning: {0}{1}. Map each to a standard tag."),
        AccessibilityRule.Links => Loc.T("Links without tags or text: {0}{1}. Tag each link and give it text."),
        AccessibilityRule.FormNames => Loc.T("Form fields without a name or tooltip: {0}{1}. Give each one both."),
        AccessibilityRule.FormTagged => Loc.T("Form fields that are not tagged: {0}{1}. Tag each field."),
        _ => "",
    };

    public static string Where(int pageIndex) => pageIndex >= 0 ? Loc.T(", first on page {0}", pageIndex + 1) : "";

    public static string ContrastNeedsPerson => Loc.T("Color contrast is not checked here. Look at the pages and make sure text stands out from its background.");
    public static string NoTags => Loc.T("There are no tags to check. Tag the document first.");
    public static string SuspectTags => Loc.T("The tags are marked as unreliable. Check them and clear the mark.");
    public static string TitleNotShown => Loc.T("The window shows the file name, not the title. Turn on showing the title.");

    public static string FigureLabel => Loc.T("Figure");
}
