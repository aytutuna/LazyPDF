using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Viewer;

namespace LazyPDF.App.Tools;

/// <summary>The pinned button under a tool's panel: what it does, when it can, and what it runs.</summary>
/// <param name="Glyph">A Segoe Fluent Icons glyph.</param>
public sealed record ToolAction(string Text, string Glyph, Func<bool> CanRun, Func<Task> Run);

/// <summary>
/// A tool's panel in the inspector, or a side panel on the rail. The shell calls <see cref="Attach"/> when
/// the panel is shown for a document and <see cref="Detach"/> when it goes or the document changes.
/// </summary>
public interface IToolPanel
{
    /// <summary>The accent button pinned under the panel; null when the tool has none.</summary>
    ToolAction? Action { get; }

    /// <summary>Raised when <see cref="Action"/> or whether it can run changed.</summary>
    event EventHandler? ActionChanged;

    void Attach(DocumentTab tab, IDocumentViewer viewer, IToolHost host);

    void Detach();
}

/// <summary>Base of the panels: keeps the document and viewer between <see cref="Attach"/> and <see cref="Detach"/>.</summary>
public abstract class ToolPanel : UserControl, IToolPanel
{
    public virtual ToolAction? Action => null;

    public event EventHandler? ActionChanged;

    protected DocumentTab? Tab { get; private set; }

    protected IDocumentViewer? Viewer { get; private set; }

    protected IToolHost? Host { get; private set; }

    public void Attach(DocumentTab tab, IDocumentViewer viewer, IToolHost host)
    {
        Tab = tab;
        Viewer = viewer;
        Host = host;
        OnAttach();
    }

    public void Detach()
    {
        OnDetach();
        Tab = null;
        Viewer = null;
        Host = null;
    }

    protected virtual void OnAttach()
    {
    }

    protected virtual void OnDetach()
    {
    }

    protected void RaiseActionChanged() => ActionChanged?.Invoke(this, EventArgs.Empty);
}
