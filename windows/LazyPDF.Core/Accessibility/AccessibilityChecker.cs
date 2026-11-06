using System.Text.RegularExpressions;

namespace LazyPDF.Core;

/// <summary>
/// The Acrobat accessibility check list and the rules of ISO 14289-1 (PDF/UA-1) that a program can
/// decide. Colour contrast and whether alt text says the right thing are left to a person. Nothing
/// here changes the document except <see cref="Fix"/>.
/// </summary>
public static partial class AccessibilityChecker
{
    private const int LongDocument = 20;
    private const int MaxLocations = 50;

    private static readonly Regex LanguageTagPattern = new(@"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*\z", RegexOptions.CultureInvariant);

    private sealed class Found
    {
        public int Count { get; private set; }
        public List<AccessibilityPlace> Where { get; } = [];

        public void Add(int pageIndex, PdfReference? element)
        {
            Count++;
            if (Where.Count < MaxLocations) Where.Add(new AccessibilityPlace(pageIndex, element));
        }
    }

    public static AccessibilityReport Check(PdfDocument document, CancellationToken cancel = default)
    {
        var tree = StructureTree.Read(document);
        var content = ReadContent(document, tree, cancel);
        var items = new List<AccessibilityItem>
        {
            Tagged(document, tree),
            Title(document),
            Language(document),
            Security(document),
            Bookmarks(document),
            content.Searchable,
            content.Encoding,
            content.TaggedContent,
            TabOrder(document),
            new(AccessibilityRule.Contrast, AccessibilityText.Name(AccessibilityRule.Contrast), AccessibilityStatus.NeedsPerson, AccessibilityText.ContrastNeedsPerson, [], AccessibilityFix.None),
        };
        items.AddRange(CheckStructure(document, tree));
        return new AccessibilityReport(items);
    }

    private static AccessibilityItem Pass(AccessibilityRule rule) =>
        new(rule, AccessibilityText.Name(rule), AccessibilityStatus.Passed, AccessibilityText.Passed(rule), [], AccessibilityFix.None);

    private static AccessibilityItem Fail(AccessibilityRule rule, Found found, AccessibilityFix fix = AccessibilityFix.None)
    {
        string message = string.Format(AccessibilityText.Failed(rule), found.Count, AccessibilityText.Where(found.Where.Count > 0 ? found.Where[0].PageIndex : -1));
        return new AccessibilityItem(rule, AccessibilityText.Name(rule), AccessibilityStatus.Failed, message, found.Where, fix);
    }

    private static AccessibilityItem Fail(AccessibilityRule rule, string? message = null, AccessibilityFix fix = AccessibilityFix.None) =>
        new(rule, AccessibilityText.Name(rule), AccessibilityStatus.Failed, message ?? AccessibilityText.Failed(rule), [], fix);

    private static AccessibilityItem NoTags(AccessibilityRule rule) =>
        new(rule, AccessibilityText.Name(rule), AccessibilityStatus.NeedsPerson, AccessibilityText.NoTags, [], AccessibilityFix.None);

    private static AccessibilityItem Tagged(PdfDocument document, StructureTree? tree)
    {
        if (document.Bool(document.Dict(document.Catalog, "MarkInfo"), "Suspects") == true) return Fail(AccessibilityRule.Tagged, AccessibilityText.SuspectTags);
        return document.IsTagged && tree is { Roots.Count: > 0 } ? Pass(AccessibilityRule.Tagged) : Fail(AccessibilityRule.Tagged);
    }

    private static AccessibilityItem Title(PdfDocument document)
    {
        if (string.IsNullOrWhiteSpace(DocumentMetadata.Read(document).Title)) return Fail(AccessibilityRule.Title, fix: AccessibilityFix.SetTitle);
        if (!ViewerSettings.Read(document).DisplayDocTitle) return Fail(AccessibilityRule.Title, AccessibilityText.TitleNotShown, AccessibilityFix.ShowTitle);
        return Pass(AccessibilityRule.Title);
    }

    private static AccessibilityItem Language(PdfDocument document)
    {
        string? language = PdfText.Read(document, document.Catalog, "Lang");
        return language is not null && LanguageTagPattern.IsMatch(language) ? Pass(AccessibilityRule.Language) : Fail(AccessibilityRule.Language, fix: AccessibilityFix.SetLanguage);
    }

    // 7.16 of ISO 14289-1: the extraction-for-accessibility permission must not be withheld.
    private static AccessibilityItem Security(PdfDocument document) =>
        document.Security is { } security && (security.Permissions & PdfPermissions.ExtractForAccessibility) == 0
            ? Fail(AccessibilityRule.Security)
            : Pass(AccessibilityRule.Security);

    private static AccessibilityItem Bookmarks(PdfDocument document) =>
        document.Pages.Count > LongDocument && Outline.Read(document).Items.Count == 0 ? Fail(AccessibilityRule.Bookmarks) : Pass(AccessibilityRule.Bookmarks);

    // 7.18.3: pages with annotations take their tab order from the structure.
    private static AccessibilityItem TabOrder(PdfDocument document)
    {
        var found = new Found();
        foreach (var page in document.Pages)
        {
            if (document.Array(page.Dictionary, "Annots") is { Items.Count: > 0 } && document.Name(page.Dictionary, "Tabs") != "S") found.Add(page.Index, page.Reference);
        }
        return found.Count == 0 ? Pass(AccessibilityRule.TabOrder) : Fail(AccessibilityRule.TabOrder, found, AccessibilityFix.SetTabOrder);
    }
}
