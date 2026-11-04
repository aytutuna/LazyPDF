using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;

namespace LazyPDF.App.Viewer;

/// <summary>
/// What a screen reader gets of the pages: one document element named by the page in view, whose value is that
/// page's text (read from the engine, in reading order, so it does not depend on what is drawn).
/// </summary>
internal sealed class PageSurfacePeer(PageSurface owner) : FrameworkElementAutomationPeer(owner), IValueProvider
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Document;

    protected override string GetClassNameCore() => "PageSurface";

    protected override string GetNameCore() =>
        owner.PageCount == 0 ? base.GetNameCore() : Loc.T("Page {0} of {1}", owner.CurrentPage + 1, owner.PageCount);

    public override object? GetPattern(PatternInterface pattern) =>
        pattern == PatternInterface.Value ? this : base.GetPattern(pattern);

    public string Value => owner.PageText?.Invoke(owner.CurrentPage) ?? "";

    public bool IsReadOnly => true;

    public void SetValue(string value) => throw new ElementNotEnabledException();

    /// <summary>The page in view changed.</summary>
    public void PageChanged()
    {
        RaisePropertyChangedEvent(AutomationElementIdentifiers.NameProperty, "", GetNameCore());
        RaisePropertyChangedEvent(ValuePatternIdentifiers.ValueProperty, "", Value);
    }
}
