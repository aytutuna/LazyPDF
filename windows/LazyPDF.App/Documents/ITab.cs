using System.ComponentModel;
using LazyPDF.Core;

namespace LazyPDF.App.Documents;

/// <summary>An entry of the tab strip: the Home tab or an open document.</summary>
public interface ITab : INotifyPropertyChanged
{
    string Title { get; }

    /// <summary>What a screen reader says for the tab: the title, and that it has unsaved changes.</summary>
    string AutomationName { get; }

    /// <summary>What a screen reader says for the tab's close button.</summary>
    string CloseAutomationName { get; }

    /// <summary>A Segoe Fluent Icons glyph.</summary>
    string Glyph { get; }

    bool IsDirty { get; }

    bool CanClose { get; }
}

/// <summary>The first tab: recent files and the jobs people come for. It stays open.</summary>
public sealed class HomeTab : ITab
{
    public static HomeTab Instance { get; } = new();

    private HomeTab()
    {
    }

    public string Title => Loc.T("Home");

    public string AutomationName => Title;

    public string CloseAutomationName => Loc.T("Close {0}", Title);

    public string Glyph => "\uE80F";

    public bool IsDirty => false;

    public bool CanClose => false;

    public event PropertyChangedEventHandler? PropertyChanged
    {
        add { }
        remove { }
    }
}
