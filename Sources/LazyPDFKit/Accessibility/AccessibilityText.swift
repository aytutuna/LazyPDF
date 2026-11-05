import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/AccessibilityText.cs: the words the accessibility layer shows.

public enum AccessibilityText {
    static var alreadyInTree: String { L10n.t("The item is already in the tree.") }
    static var rootNeedsElement: String { L10n.t("Only an element can sit at the root.") }
    static var intoItself: String { L10n.t("An element cannot go into itself.") }
    static var treeTooLarge: String { L10n.t("The structure tree is too large to edit.") }

    public static func name(_ rule: AccessibilityRule) -> String {
        switch rule {
        case .tagged: return L10n.t("Document is tagged")
        case .title: return L10n.t("Title is set and shown")
        case .language: return L10n.t("Language is set")
        case .security: return L10n.t("Security allows screen readers")
        case .bookmarks: return L10n.t("Long document has bookmarks")
        case .searchable: return L10n.t("Pages have text")
        case .encoding: return L10n.t("Fonts map to text")
        case .taggedContent: return L10n.t("All content is tagged")
        case .tabOrder: return L10n.t("Tab order follows structure")
        case .contrast: return L10n.t("Colour contrast")
        case .figureAlt: return L10n.t("Figures have alt text")
        case .tableStructure: return L10n.t("Tables are well formed")
        case .tableHeaders: return L10n.t("Tables have headers")
        case .listStructure: return L10n.t("Lists are well formed")
        case .headingOrder: return L10n.t("Headings are in order")
        case .roleMap: return L10n.t("Custom tags are mapped")
        case .links: return L10n.t("Links have text")
        case .formNames: return L10n.t("Form fields have names and tooltips")
        case .formTagged: return L10n.t("Form fields are tagged")
        }
    }

    public static func passed(_ rule: AccessibilityRule) -> String {
        switch rule {
        case .tagged: return L10n.t("The document is tagged.")
        case .title: return L10n.t("The title is set and the window shows it.")
        case .language: return L10n.t("The document language is set.")
        case .security: return L10n.t("The security settings allow screen readers.")
        case .bookmarks: return L10n.t("The document has bookmarks, or is short enough not to need them.")
        case .searchable: return L10n.t("Every page with pictures also has text.")
        case .encoding: return L10n.t("Every font maps its characters to text.")
        case .taggedContent: return L10n.t("All page content is tagged or marked as an artifact.")
        case .tabOrder: return L10n.t("Pages with links or fields follow the structure order.")
        case .contrast: return ""
        case .figureAlt: return L10n.t("Every figure has alt text, or there are no figures.")
        case .tableStructure: return L10n.t("Every table has rows and cells in the right places, or there are no tables.")
        case .tableHeaders: return L10n.t("Every table has header cells, or there are no tables.")
        case .listStructure: return L10n.t("Every list has items, labels and bodies in the right places, or there are no lists.")
        case .headingOrder: return L10n.t("Headings go down one level at a time, or there are none.")
        case .roleMap: return L10n.t("Every custom tag maps to a standard one.")
        case .links: return L10n.t("Every link is tagged and has text.")
        case .formNames: return L10n.t("Every form field has a name and a tooltip, or there are no fields.")
        case .formTagged: return L10n.t("Every form field is tagged, or there are no fields.")
        }
    }

    // {0} is how many places are affected, {1} where the first is.
    public static func failed(_ rule: AccessibilityRule) -> String {
        switch rule {
        case .tagged: return L10n.t("The document has no tags. Add tags so a screen reader can read it in order.")
        case .title: return L10n.t("The document has no title. Give it one so the window and the reader can name it.")
        case .language: return L10n.t("The document language is missing or not valid. Set it so a screen reader picks the right voice.")
        case .security: return L10n.t("The security settings stop screen readers from reading the text. Allow text access for accessibility.")
        case .bookmarks: return L10n.t("The document is long and has no bookmarks. Add bookmarks for its sections.")
        case .searchable: return L10n.t("Pages with only pictures: {0}{1}. Run text recognition so the words can be read.")
        case .encoding: return L10n.t("Fonts that give no text: {0}{1}. Create the file again with fonts that map to text.")
        case .taggedContent: return L10n.t("Pages with content not in the tags: {0}{1}. Tag it or mark it as an artifact.")
        case .tabOrder: return L10n.t("Pages not using structure order: {0}{1}. Set the tab order to follow the structure.")
        case .contrast: return ""
        case .figureAlt: return L10n.t("Figures without alt text: {0}{1}. Describe each one.")
        case .tableStructure: return L10n.t("Tables with a broken layout: {0}{1}. Give each table rows of header and data cells, with the same cells in every row.")
        case .tableHeaders: return L10n.t("Tables without header cells: {0}{1}. Mark the header row or column.")
        case .listStructure: return L10n.t("Lists with items in the wrong place: {0}{1}. Put labels and bodies inside list items.")
        case .headingOrder: return L10n.t("Headings out of order: {0}{1}. Start at level 1 and go down one level at a time.")
        case .roleMap: return L10n.t("Custom tags without a standard meaning: {0}{1}. Map each to a standard tag.")
        case .links: return L10n.t("Links without tags or text: {0}{1}. Tag each link and give it text.")
        case .formNames: return L10n.t("Form fields without a name or tooltip: {0}{1}. Give each one both.")
        case .formTagged: return L10n.t("Form fields that are not tagged: {0}{1}. Tag each field.")
        }
    }

    public static func `where`(_ pageIndex: Int) -> String {
        pageIndex >= 0 ? L10n.t(", first on page {0}", pageIndex + 1) : ""
    }

    public static var contrastNeedsPerson: String { L10n.t("Colour contrast is not checked here. Look at the pages and make sure text stands out from its background.") }
    public static var noTags: String { L10n.t("There are no tags to check. Tag the document first.") }
    public static var suspectTags: String { L10n.t("The tags are marked as unreliable. Check them and clear the mark.") }
    public static var titleNotShown: String { L10n.t("The window shows the file name, not the title. Turn on showing the title.") }

    public static var figureLabel: String { L10n.t("Figure") }
}
