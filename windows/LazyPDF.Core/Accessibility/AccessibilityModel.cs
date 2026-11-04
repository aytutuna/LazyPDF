namespace LazyPDF.Core;

public enum AccessibilityStatus { Passed, Failed, NeedsPerson }

/// <summary>The checks, in the order of the Acrobat list; the ISO 14289-1 rule each one covers is in <see cref="AccessibilityChecker"/>.</summary>
public enum AccessibilityRule
{
    Tagged,
    Title,
    Language,
    Security,
    Bookmarks,
    Searchable,
    Encoding,
    TaggedContent,
    TabOrder,
    Contrast,
    FigureAlt,
    TableStructure,
    TableHeaders,
    ListStructure,
    HeadingOrder,
    RoleMap,
    Links,
    FormNames,
    FormTagged,
}

/// <summary>A repair <see cref="AccessibilityChecker.Fix"/> can make.</summary>
public enum AccessibilityFix
{
    None,

    /// <summary>Needs the title as the value.</summary>
    SetTitle,

    /// <summary>The file has a title; make the window show it.</summary>
    ShowTitle,

    /// <summary>Needs a BCP 47 tag as the value.</summary>
    SetLanguage,

    /// <summary>/Tabs /S on every page with annotations.</summary>
    SetTabOrder,
}

/// <param name="PageIndex">From 0, -1 when the place is not on a page.</param>
/// <param name="Element">The structure element at fault, when there is one; the object of the annotation or field otherwise.</param>
public sealed record AccessibilityPlace(int PageIndex, PdfReference? Element);

/// <param name="Message">One or two plain sentences: what is wrong and what to do.</param>
/// <param name="Where">Up to 50 places; the message counts all of them.</param>
public sealed record AccessibilityItem(
    AccessibilityRule Rule, string Name, AccessibilityStatus Status, string Message, IReadOnlyList<AccessibilityPlace> Where, AccessibilityFix Fix);

public sealed record AccessibilityReport(IReadOnlyList<AccessibilityItem> Items)
{
    public int Passed => Items.Count(i => i.Status == AccessibilityStatus.Passed);
    public int Failed => Items.Count(i => i.Status == AccessibilityStatus.Failed);
    public int NeedsPerson => Items.Count(i => i.Status == AccessibilityStatus.NeedsPerson);

    public AccessibilityItem this[AccessibilityRule rule] => Items.First(i => i.Rule == rule);
}
