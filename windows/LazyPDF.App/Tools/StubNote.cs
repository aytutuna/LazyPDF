using System.Windows;
using System.Windows.Controls;

namespace LazyPDF.App.Tools;

/// <summary>What a panel shows until its tool is built: the tool's sentence and a line saying it is not there yet.</summary>
internal sealed class StubNote : StackPanel
{
    public StubNote(string id, bool side = false)
    {
        string summary = (side ? ToolCatalog.FindSide(id)?.Summary : ToolCatalog.Find(id)?.Summary) ?? "";
        Margin = new Thickness(12, 8, 12, 12);
        Children.Add(new TextBlock { Text = summary, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.FindResource("BodyText") });

        var reason = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        var glyph = new TextBlock { Text = "\uE946", Style = (Style)Application.Current.FindResource("ReasonGlyph") };
        DockPanel.SetDock(glyph, Dock.Left);
        reason.Children.Add(glyph);
        reason.Children.Add(new TextBlock { Text = Loc.T("Not available yet."), Style = (Style)Application.Current.FindResource("ReasonText") });
        Children.Add(reason);
    }
}
