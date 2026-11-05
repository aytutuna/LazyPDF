using LazyPDF.Core;

namespace LazyPDF.App.Tools.Accessibility;

public enum RowAction
{
    None,
    SetTabOrder,
    AddTags,
    DescribeFigures,
}

/// <summary>Title and language carry a box of their own so they can be changed whether the check passed or not.</summary>
public enum RowEditor
{
    None,
    Title,
    Language,
}

/// <summary>One line of the check: the result in plain words, what can be done about it, and where the trouble is.</summary>
public sealed class CheckRow(AccessibilityItem item, string value = "", bool canAddTags = true)
{
    private readonly string _start = value;
    private readonly int[] _pages = item.Where.Where(p => p.PageIndex >= 0).Select(p => p.PageIndex).Distinct().ToArray();
    private int _next;

    public string Name => item.Name;

    public string Message => item.Message;

    /// <summary>What the title or language box holds.</summary>
    public string Value { get; set; } = value;

    /// <summary>The box holds something other than what it started with.</summary>
    public bool Edited => Value.Trim() != _start.Trim();

    public string Status => item.Status switch
    {
        AccessibilityStatus.Passed => Loc.T("Passed"),
        AccessibilityStatus.Failed => Loc.T("Failed"),
        _ => Loc.T("Needs a person"),
    };

    public string Glyph => item.Status switch
    {
        AccessibilityStatus.Passed => "",
        AccessibilityStatus.Failed => "",
        _ => "",
    };

    /// <summary>The status by name, for the colours of the template.</summary>
    public string Level => item.Status.ToString();

    public string Summary => Name + ", " + Status + ". " + Message;

    public RowEditor Editor => item.Rule switch
    {
        AccessibilityRule.Title => RowEditor.Title,
        AccessibilityRule.Language => RowEditor.Language,
        _ => RowEditor.None,
    };

    public bool HasEditor => Editor != RowEditor.None;

    public string EditorName => Editor == RowEditor.Title ? Loc.T("Title") : Loc.T("Language");

    public string SaveText => Editor == RowEditor.Title ? Loc.T("Save title") : Loc.T("Save language");

    public RowAction Action
    {
        get
        {
            if (item.Status != AccessibilityStatus.Failed) return RowAction.None;
            if (item.Fix == AccessibilityFix.SetTabOrder) return RowAction.SetTabOrder;
            return item.Rule switch
            {
                AccessibilityRule.Tagged => canAddTags ? RowAction.AddTags : RowAction.None,
                AccessibilityRule.FigureAlt => RowAction.DescribeFigures,
                _ => RowAction.None,
            };
        }
    }

    public bool HasAction => Action != RowAction.None;

    public string ActionText => Action switch
    {
        RowAction.SetTabOrder => Loc.T("Set the tab order"),
        RowAction.AddTags => Loc.T("Add tags"),
        RowAction.DescribeFigures => Loc.T("Describe figures"),
        _ => "",
    };

    public bool HasPlaces => _pages.Length > 0;

    public string PlaceText => _pages.Length == 0 ? "" : Loc.T("Go to page {0}", _pages[_next % _pages.Length] + 1);

    /// <summary>The page the place button goes to; the next press goes to the following place.</summary>
    public int NextPage()
    {
        int page = _pages[_next % _pages.Length];
        _next++;
        return page;
    }
}
