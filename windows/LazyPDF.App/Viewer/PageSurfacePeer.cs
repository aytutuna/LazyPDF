using System.Windows;
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

    protected override string GetNameCore()
    {
        if (owner.PageCount == 0) return base.GetNameCore();
        string label = owner.PageLabel?.Invoke(owner.CurrentPage) ?? "";
        return label.Length > 0 && label != (owner.CurrentPage + 1).ToString()
            ? Loc.T("Page {0} ({1} of {2})", label, owner.CurrentPage + 1, owner.PageCount)
            : Loc.T("Page {0} of {1}", owner.CurrentPage + 1, owner.PageCount);
    }

    protected override List<AutomationPeer>? GetChildrenCore()
    {
        if (owner.PageLinks is not { } links || owner.PageCount == 0) return null;
        var peers = new List<AutomationPeer>();
        foreach (int page in owner.Layout.PagesIn(owner.ViewRect))
            foreach (var link in links(page)) peers.Add(new LinkPeer(owner, page, link));
        return peers.Count == 0 ? null : peers;
    }

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

    /// <summary>The links in view changed.</summary>
    public void LinksChanged()
    {
        ResetChildrenCache();
        if (ListenerExists(AutomationEvents.StructureChanged)) RaiseAutomationEvent(AutomationEvents.StructureChanged);
    }
}

/// <summary>A link on a page: it can be focused and followed, so a screen reader lists it and can act on it.</summary>
internal sealed class LinkPeer(PageSurface surface, int page, LinkTarget target) : AutomationPeer, IInvokeProvider
{
    protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Hyperlink;

    protected override string GetClassNameCore() => "Link";

    protected override List<AutomationPeer>? GetChildrenCore() => null;

    protected override string GetNameCore() => target.Name;

    protected override string GetAutomationIdCore() => "";

    protected override Rect GetBoundingRectangleCore()
    {
        if (surface.PageMatrix(page) is not { } matrix) return Rect.Empty;
        var area = Rect.Intersect(new Rect(matrix.Transform(target.Area.TopLeft), matrix.Transform(target.Area.BottomRight)), new Rect(surface.Viewport));
        if (area.IsEmpty) return Rect.Empty;
        return new Rect(surface.PointToScreen(area.TopLeft), surface.PointToScreen(area.BottomRight));
    }

    protected override Point GetClickablePointCore()
    {
        var area = GetBoundingRectangleCore();
        return area.IsEmpty ? new Point(double.NaN, double.NaN) : new Point(area.X + area.Width / 2, area.Y + area.Height / 2);
    }

    protected override bool IsOffscreenCore() => GetBoundingRectangleCore().IsEmpty;

    protected override bool IsKeyboardFocusableCore() => true;

    protected override bool HasKeyboardFocusCore() => false;

    protected override bool IsEnabledCore() => true;

    protected override bool IsControlElementCore() => true;

    protected override bool IsContentElementCore() => true;

    protected override bool IsPasswordCore() => false;

    protected override bool IsRequiredForFormCore() => false;

    protected override string GetAcceleratorKeyCore() => "";

    protected override string GetAccessKeyCore() => "";

    protected override string GetHelpTextCore() => "";

    protected override string GetItemStatusCore() => "";

    protected override string GetItemTypeCore() => "";

    protected override AutomationPeer? GetLabeledByCore() => null;

    protected override AutomationOrientation GetOrientationCore() => AutomationOrientation.None;

    protected override void SetFocusCore() => target.Focus();

    public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.Invoke ? this : null;

    public void Invoke() => surface.Dispatcher.BeginInvoke(target.Follow);
}
