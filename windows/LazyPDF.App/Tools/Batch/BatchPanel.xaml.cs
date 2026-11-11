using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;

namespace LazyPDF.App.Tools.Batch;

public sealed record StepRow(BatchStep Step, string Title, string Detail)
{
    public string Spoken => $"{Title}, {Detail}";
}

public sealed record FileRow(string Path)
{
    public string Name => System.IO.Path.GetFileName(Path);

    public string RemoveName => Loc.T("Remove {0}", Name);
}

public sealed record LogRow(BatchResult Result)
{
    public string Path => Result.Input;

    public string Name => System.IO.Path.GetFileName(Result.Input);

    public string Title => Result.Title;

    public string Detail => Result.Detail;

    public string Glyph => Result.Ok ? "" : "";

    public string Spoken => $"{Name}, {Title}. {Detail}";
}

/// <summary>
/// The same steps over many files: a list of steps with their settings, the files or a watched folder to run them
/// on, a log of what happened to each, and sets that are kept by name. A watched folder keeps being served while another tool is open.
/// </summary>
public partial class BatchPanel : ToolPanel
{
    private readonly BatchSetStore _store = new();
    private readonly BatchSet _set = new();
    private readonly List<string> _files = [];
    private readonly HashSet<string> _known = new(StringComparer.OrdinalIgnoreCase);
    private bool _folderFailed;
    private readonly ObservableCollection<LogRow> _log = [];
    private BatchRunner? _runner;
    private bool _running;
    private bool _loading;

    public BatchPanel()
    {
        InitializeComponent();
        Summary.Text = ToolCatalog.Find("batch")?.Summary;
        TemplateHint.Text = Loc.T("Use {0}, {1} and {2}. A name that is taken gets a number.", "{name}", "{n}", "{date}");
        TemplateBox.Text = _set.NameTemplate;
        LogList.ItemsSource = _log;
        FillChoices();
        ShowSets();
        ShowSteps();
        ShowFiles();
        ShowLog();
        ShowWatch();
        Action = BuildAction();
    }

    public override ToolAction? Action { get; }

    private ToolAction BuildAction() =>
        new(Loc.T("Run on every file"), "", () => _files.Count > 0 && _set.Steps.Count > 0 && _set.OutputFolder.Length > 0 && !_running, RunAsync);

    private BatchRunner Runner => _runner ??= new BatchRunner(new WicImageCodec(), new SystemFontSource(), new WindowsOcr(), () => new WindowsPageRenderer());

    private void ShowSets()
    {
        string text = SetBox.Text;
        SetBox.ItemsSource = _store.Load().Select(s => s.Name).ToList();
        SetBox.Text = text;
        DeleteSetButton.IsEnabled = SetBox.Items.Contains(text);
    }

    private void SetBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SetBox.SelectedItem is not string name || _store.Load().FirstOrDefault(s => s.Name == name) is not { } saved) return;
        _set.Name = saved.Name;
        _set.Steps = [.. saved.Steps.Select(s => s.Copy())];
        _set.OutputFolder = saved.OutputFolder;
        _set.NameTemplate = saved.NameTemplate;
        _set.WatchFolder = saved.WatchFolder;
        _loading = true;
        TemplateBox.Text = _set.NameTemplate;
        _loading = false;
        ShowSteps();
        RecheckWatch();
        ShowWatch();
        RaiseActionChanged();
    }

    private void SetBox_TextChanged(object sender, TextChangedEventArgs e) =>
        DeleteSetButton.IsEnabled = SetBox.Items.Contains(SetBox.Text);

    private void SaveSet_Click(object sender, RoutedEventArgs e)
    {
        string name = SetBox.Text.Trim();
        if (name.Length == 0)
        {
            Host?.ShowProblem(new Problem(Loc.T("Set has no name"), Loc.T("Type a name for the set, then save it.")));
            return;
        }
        _set.Name = name;
        _store.Save(_set.Copy());
        ShowSets();
        Host?.SetStatus(Loc.T("Saved {0}", name));
    }

    private void DeleteSet_Click(object sender, RoutedEventArgs e)
    {
        string name = SetBox.Text;
        _store.Delete(name);
        SetBox.Text = "";
        ShowSets();
        Host?.SetStatus(Loc.T("Deleted {0}", name));
    }
}
