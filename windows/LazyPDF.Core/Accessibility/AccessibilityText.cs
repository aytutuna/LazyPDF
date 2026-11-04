namespace LazyPDF.Core;

// User-visible words of this layer, in one place until Loc.T exists.
public static class AccessibilityText
{
    internal const string AlreadyInTree = "The item is already in the tree.";
    internal const string RootNeedsElement = "Only an element can sit at the root.";
    internal const string IntoItself = "An element cannot go into itself.";
    internal const string TreeTooLarge = "The structure tree is too large to edit.";

    public static string Name(AccessibilityRule rule) => rule switch
    {
        AccessibilityRule.Tagged => "Document is tagged",
        AccessibilityRule.Title => "Title is set and shown",
        AccessibilityRule.Language => "Language is set",
        AccessibilityRule.Security => "Security allows screen readers",
        AccessibilityRule.Bookmarks => "Long document has bookmarks",
        AccessibilityRule.Searchable => "Pages have text",
        AccessibilityRule.Encoding => "Fonts map to text",
        AccessibilityRule.TaggedContent => "All content is tagged",
        AccessibilityRule.TabOrder => "Tab order follows structure",
        AccessibilityRule.Contrast => "Colour contrast",
        AccessibilityRule.FigureAlt => "Figures have alt text",
        AccessibilityRule.TableStructure => "Tables are well formed",
        AccessibilityRule.TableHeaders => "Tables have headers",
        AccessibilityRule.ListStructure => "Lists are well formed",
        AccessibilityRule.HeadingOrder => "Headings are in order",
        AccessibilityRule.RoleMap => "Custom tags are mapped",
        AccessibilityRule.Links => "Links have text",
        AccessibilityRule.FormNames => "Form fields have names and tooltips",
        AccessibilityRule.FormTagged => "Form fields are tagged",
        _ => rule.ToString(),
    };

    public static string Passed(AccessibilityRule rule) => rule switch
    {
        AccessibilityRule.Tagged => "The document is tagged.",
        AccessibilityRule.Title => "The title is set and the window shows it.",
        AccessibilityRule.Language => "The document language is set.",
        AccessibilityRule.Security => "The security settings allow screen readers.",
        AccessibilityRule.Bookmarks => "The document has bookmarks, or is short enough not to need them.",
        AccessibilityRule.Searchable => "Every page with pictures also has text.",
        AccessibilityRule.Encoding => "Every font maps its characters to text.",
        AccessibilityRule.TaggedContent => "All page content is tagged or marked as an artifact.",
        AccessibilityRule.TabOrder => "Pages with links or fields follow the structure order.",
        AccessibilityRule.FigureAlt => "Every figure has alt text, or there are no figures.",
        AccessibilityRule.TableStructure => "Every table has rows and cells in the right places, or there are no tables.",
        AccessibilityRule.TableHeaders => "Every table has header cells, or there are no tables.",
        AccessibilityRule.ListStructure => "Every list has items, labels and bodies in the right places, or there are no lists.",
        AccessibilityRule.HeadingOrder => "Headings go down one level at a time, or there are none.",
        AccessibilityRule.RoleMap => "Every custom tag maps to a standard one.",
        AccessibilityRule.Links => "Every link is tagged and has text.",
        AccessibilityRule.FormNames => "Every form field has a name and a tooltip, or there are no fields.",
        AccessibilityRule.FormTagged => "Every form field is tagged, or there are no fields.",
        _ => "",
    };

    // {0} is how many places are affected, {1} where the first is.
    public static string Failed(AccessibilityRule rule) => rule switch
    {
        AccessibilityRule.Tagged => "The document has no tags. Add tags so a screen reader can read it in order.",
        AccessibilityRule.Title => "The document has no title. Give it one so the window and the reader can name it.",
        AccessibilityRule.Language => "The document language is missing or not valid. Set it so a screen reader picks the right voice.",
        AccessibilityRule.Security => "The security settings stop screen readers from reading the text. Allow text access for accessibility.",
        AccessibilityRule.Bookmarks => "The document is long and has no bookmarks. Add bookmarks for its sections.",
        AccessibilityRule.Searchable => "Pages with only pictures: {0}{1}. Run text recognition so the words can be read.",
        AccessibilityRule.Encoding => "Fonts that give no text: {0}{1}. Create the file again with fonts that map to text.",
        AccessibilityRule.TaggedContent => "Pages with content not in the tags: {0}{1}. Tag it or mark it as an artifact.",
        AccessibilityRule.TabOrder => "Pages not using structure order: {0}{1}. Set the tab order to follow the structure.",
        AccessibilityRule.FigureAlt => "Figures without alt text: {0}{1}. Describe each one.",
        AccessibilityRule.TableStructure => "Tables with a broken layout: {0}{1}. Give each table rows of header and data cells, with the same cells in every row.",
        AccessibilityRule.TableHeaders => "Tables without header cells: {0}{1}. Mark the header row or column.",
        AccessibilityRule.ListStructure => "Lists with items in the wrong place: {0}{1}. Put labels and bodies inside list items.",
        AccessibilityRule.HeadingOrder => "Headings out of order: {0}{1}. Start at level 1 and go down one level at a time.",
        AccessibilityRule.RoleMap => "Custom tags without a standard meaning: {0}{1}. Map each to a standard tag.",
        AccessibilityRule.Links => "Links without tags or text: {0}{1}. Tag each link and give it text.",
        AccessibilityRule.FormNames => "Form fields without a name or tooltip: {0}{1}. Give each one both.",
        AccessibilityRule.FormTagged => "Form fields that are not tagged: {0}{1}. Tag each field.",
        _ => "",
    };

    public static string Where(int pageIndex) => pageIndex >= 0 ? $", first on page {pageIndex + 1}" : "";

    public const string ContrastNeedsPerson = "Colour contrast is not checked here. Look at the pages and make sure text stands out from its background.";
    public const string NoTags = "There are no tags to check. Tag the document first.";
    public const string SuspectTags = "The tags are marked as unreliable. Check them and clear the mark.";
    public const string TitleNotShown = "The window shows the file name, not the title. Turn on showing the title.";

    public const string FigureLabel = "Figure";
}
