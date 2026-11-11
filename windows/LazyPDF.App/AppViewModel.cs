using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using LazyPDF.Core;

namespace LazyPDF.App;

/// <summary>A button the info bar offers beside its message.</summary>
public sealed record NoticeAction(string Text, Action Run);

/// <summary>What the info bar says: a title, the sentence under it and, if it helps, a button.</summary>
public sealed record InfoMessage(string Title, string Text, bool IsError, NoticeAction? Action = null);

/// <summary>
/// The state of the window: the tabs, the tool and side panel in use, the info bar and the busy bar. The window
/// reads it back whenever it raises <see cref="PropertyChanged"/> with an empty name, as in the sisters.
/// Documents, recovery, the home tiles and printing are in the partial files.
/// </summary>
public sealed partial class AppViewModel : INotifyPropertyChanged, IToolHost
{
    private readonly Func<IDocumentRenderer> _renderers;
    private readonly DocumentOpener _opener;
    private readonly ISisterApps _sisters;
    private readonly RecoveryStore _recovery;
    private readonly RecentFiles _recentFiles;
    private readonly string? _settingsDirectory;
    private readonly string _printDirectory;
    private ITab _activeTab = HomeTab.Instance;
    private DocumentTab? _lastDocument;
    private string? _activeToolId;
    private string _sidePanelId;
    private string _lastSidePanelId;
    private InfoMessage? _message;
    private UIElement? _stage;
    private string _status = "";
    private CancellationTokenSource? _busy;
    private string _busyText = "";

    public AppViewModel(Func<IDocumentRenderer> renderers, IImageCodec codec, IFontSource fonts, ISisterApps sisters,
                        string? settingsDirectory = null, string? recoveryDirectory = null, string? printDirectory = null)
    {
        _renderers = renderers;
        _opener = new DocumentOpener(codec, fonts);
        _sisters = sisters;
        _settingsDirectory = settingsDirectory;
        _printDirectory = printDirectory ?? AppFolders.PrintCopies;
        _recovery = new RecoveryStore(recoveryDirectory);
        _recentFiles = new RecentFiles(settingsDirectory);
        _sidePanelId = AppPreferencesStore.Load(settingsDirectory ?? StoreFiles.DefaultDirectory).SidePanel;
        _lastSidePanelId = _sidePanelId.Length > 0 ? _sidePanelId : "pages";
        Recent = BuildRecent();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The Home tab first, then the open documents in the order shown.</summary>
    public ObservableCollection<ITab> Strip { get; } = [HomeTab.Instance];

    public IEnumerable<DocumentTab> Documents => Strip.OfType<DocumentTab>();

    public ITab ActiveTab
    {
        get => _activeTab;
        set
        {
            if (value is null || ReferenceEquals(_activeTab, value) || !Strip.Contains(value)) return;
            _activeTab = value;
            DropAction();
            if (value is DocumentTab document) _lastDocument = document;
            NotifyAll();
            _ = CheckDiskAsync();
        }
    }

    public DocumentTab? ActiveDocument => _activeTab as DocumentTab;

    public bool IsHome => _activeTab is HomeTab;

    /// <summary>The id of the tool whose panel the inspector shows; null for none.</summary>
    public string? ActiveToolId => _activeToolId;

    public ToolInfo? ActiveTool => _activeToolId is null ? null : ToolCatalog.Find(_activeToolId);

    /// <summary>The id of the side panel open beside the stage; empty when the rail is collapsed.</summary>
    public string SidePanelId => _sidePanelId;

    public InfoMessage? Message => _message;

    /// <summary>The status sentence in full, for screen readers.</summary>
    public string StatusFull => _status;

    public string StatusShort => StatusLine.Short(_status);

    /// <summary>What a tool put on the stage in place of the viewer; null while the viewer shows.</summary>
    public UIElement? HeldStage => _stage;

    public bool IsBusy => _busy is not null;

    public string BusyText => _busyText;

    public void HoldStage(UIElement? view)
    {
        if (ReferenceEquals(_stage, view)) return;
        _stage = view;
        NotifyAll();
    }

    public void SelectTool(string? id)
    {
        if (id is not null && ToolCatalog.Find(id) is null) return;
        _activeToolId = id == _activeToolId ? null : id;
        DropAction();
        NotifyAll();
    }

    /// <summary>Opens the side panel <paramref name="id"/>, or closes the rail's panel when that one is open already.</summary>
    public void SetSidePanel(string id)
    {
        _sidePanelId = id == _sidePanelId ? "" : id;
        if (_sidePanelId.Length > 0) _lastSidePanelId = _sidePanelId;
        AppPreferencesStore.Update(preferences => preferences.SidePanel = _sidePanelId, _settingsDirectory ?? StoreFiles.DefaultDirectory);
        NotifyAll();
    }

    /// <summary>Collapses the rail's panel, or opens the one that was open last.</summary>
    public void ToggleSidePanel() => SetSidePanel(_sidePanelId.Length > 0 ? _sidePanelId : _lastSidePanelId);

    public void SetAppearance(AppAppearance appearance)
    {
        ThemeService.Apply(appearance);
        AppPreferencesStore.Update(preferences => preferences.Appearance = appearance, _settingsDirectory ?? StoreFiles.DefaultDirectory);
        NotifyAll();
    }

    // A button on the info bar acts on the tab and tool it was made for, so it goes when they do.
    private void DropAction()
    {
        if (_message?.Action is not null) _message = null;
    }

    public void ShowNotice(string title, string text, NoticeAction? action = null)
    {
        _message = new InfoMessage(title, text, false, action);
        NotifyAll();
    }

    public void ShowProblem(Problem problem)
    {
        _message = new InfoMessage(problem.Title, problem.Text, true);
        NotifyAll();
    }

    public void DismissMessage()
    {
        _message = null;
        NotifyAll();
    }

    public void SetStatus(string sentence)
    {
        _status = sentence;
        NotifyAll();
    }

    /// <summary>Runs <paramref name="work"/> with the busy bar showing <paramref name="text"/> and a Cancel that ends it.</summary>
    public async Task RunBusyAsync(string text, Func<CancellationToken, Task> work)
    {
        var source = new CancellationTokenSource();
        _busy = source;
        _busyText = text;
        NotifyAll();
        try
        {
            await work(source.Token);
        }
        catch (OperationCanceledException)
        {
            SetStatus(Loc.T("Cancelled."));
        }
        catch (PdfPermissionException)
        {
            // Only Core's refusal; a file system error is the tool's to explain.
            ShowProblem(Problems.Restricted());
        }
        finally
        {
            // A job that started over this one must keep the bar.
            if (ReferenceEquals(_busy, source))
            {
                _busy = null;
                _busyText = "";
            }
            source.Dispose();
            NotifyAll();
        }
    }

    public void SetBusyText(string text)
    {
        if (_busy is null) return;
        _busyText = text;
        NotifyAll();
    }

    public void CancelBusy() => _busy?.Cancel();

    /// <summary>The window raises this once everything that had unsaved changes has been dealt with.</summary>
    public event EventHandler? ExitRequested;

    /// <summary>Raised when Save anyway has saved a tab that was being closed (not during an exit): the window closes it through its own checks.</summary>
    public event EventHandler<DocumentTab>? CloseRequested;

    private void NotifyAll() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    private void RaiseExit() => ExitRequested?.Invoke(this, EventArgs.Empty);
}
