// The files, the results folder, running the steps and the watched folder.

using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Batch;

public partial class BatchPanel
{
    // One file at a time, so a run and the watcher never share the Bates numbers or the output names.
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Queue<string> _arrived = new();
    private FolderWatcher? _watcher;
    private CancellationTokenSource? _watchCancel;
    private bool _draining;
    private string _watchedFolder = "";
    private int _watched;

    private void ShowFiles()
    {
        FileList.ItemsSource = _files.Select(f => new FileRow(f)).ToList();
        NoFiles.Visibility = _files.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        RaiseActionChanged();
    }

    private void ShowLog()
    {
        NoLog.Visibility = _log.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ClearLogButton.IsEnabled = _log.Count > 0;
    }

    private void ShowWatch()
    {
        OutputBox.Text = _set.OutputFolder;
        WatchBox.Text = _set.WatchFolder;
        WatchToggle.IsChecked = _watcher is not null;
        WatchNote.Text = _watcher is null
            ? Loc.T("PDFs that appear in the folder are run through the steps.")
            : Loc.T("Watching {0}.", _watchedFolder);
    }

    private void Template_Changed(object sender, TextChangedEventArgs e)
    {
        if (!_loading) _set.NameTemplate = TemplateBox.Text;
    }

    private void BrowseOutput_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = Loc.T("Results folder"), InitialDirectory = _set.OutputFolder };
        if (dialog.ShowDialog() != true) return;
        _set.OutputFolder = dialog.FolderName;
        RecheckWatch();
        ShowWatch();
        RaiseActionChanged();
    }

    private void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Multiselect = true, Filter = Loc.T("PDF files") + "|*.pdf" };
        if (dialog.ShowDialog() != true) return;
        AddFiles(dialog.FileNames);
    }

    private void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = Loc.T("Folder of PDFs") };
        if (dialog.ShowDialog() != true) return;
        AddFiles(PdfsIn(dialog.FolderName));
    }

    private void Panel_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    private void Panel_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        _folderFailed = false;
        var pdfs = paths.SelectMany(p => Directory.Exists(p) ? PdfsIn(p) : [p])
            .Where(p => string.Equals(System.IO.Path.GetExtension(p), ".pdf", StringComparison.OrdinalIgnoreCase)).ToList();
        if (pdfs.Count > 0) AddFiles(pdfs);
        else if (!_folderFailed) Host?.SetStatus(Loc.T("Only PDF files can be added."));
    }

    internal List<string> PdfsIn(string folder)
    {
        try
        {
            var found = Directory.EnumerateFiles(folder, "*.pdf").ToList();
            found.Sort(StringComparer.CurrentCultureIgnoreCase);
            return found;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _folderFailed = true;
            var leaf = System.IO.Path.GetFileName(folder.TrimEnd('\\', '/'));
            Host?.ShowProblem(new Problem(Loc.T("Folder not read"),
                Loc.T("{0} could not be read. Check that it is there and that you may open it.", leaf.Length > 0 ? leaf : folder)));
            return [];
        }
    }

    internal void AddFiles(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            if (_known.Add(path)) _files.Add(path);
        }
        ShowFiles();
    }

    private void RemoveFile_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not FileRow row) return;
        _files.Remove(row.Path);
        _known.Remove(row.Path);
        ShowFiles();
    }

    private void ClearLog_Click(object sender, RoutedEventArgs e)
    {
        _log.Clear();
        ShowLog();
    }

    private void AddLog(BatchResult result)
    {
        _log.Insert(0, new LogRow(result));
        ShowLog();
    }

    private async Task RunAsync()
    {
        var set = _set.Copy();
        var live = _set.Steps.ToList();
        var files = _files.ToList();
        int failed = 0;
        bool cancelled = false;
        _running = true;
        RaiseActionChanged();
        try
        {
            await Host!.RunBusyAsync(Loc.T("Running the steps"), async token =>
            {
                for (int i = 0; i < files.Count; i++)
                {
                    Host?.SetStatus(Loc.T("File {0} of {1}", i + 1, files.Count));
                    BatchResult result;
                    try
                    {
                        result = await RunOneAsync(files[i], set, live, i + 1, token);
                    }
                    catch (OperationCanceledException)
                    {
                        cancelled = true;
                        return;
                    }
                    AddLog(result);
                    if (result.Ok)
                    {
                        _files.Remove(files[i]);
                        _known.Remove(files[i]);
                    }
                    else failed++;
                }
            });
        }
        finally
        {
            _running = false;
            ShowFiles();
        }
        Host?.SetStatus(cancelled ? Loc.T("Cancelled.") : failed == 0 ? Loc.T("All files done") : Loc.Plural(failed, "{0} file failed", "{0} files failed"));
    }

    // <paramref name="live"/> are the steps on screen that <paramref name="set"/> was copied from, in the same order.
    internal async Task<BatchResult> RunOneAsync(string path, BatchSet set, IReadOnlyList<BatchStep> live, int number, CancellationToken token)
    {
        await _gate.WaitAsync(token);
        try
        {
            for (int i = 0; i < live.Count; i++)
            {
                if (live[i].Kind == BatchStepKind.Bates) set.Steps[i].Start = live[i].Start;
            }
            var result = await Task.Run(() => Runner.RunAsync(path, set, number, DateTimeOffset.Now, token), token);
            if (result.Ok) ContinueNumbers(set, live);
            return result;
        }
        finally
        {
            _gate.Release();
        }
    }

    // A Bates step of the set that ran holds the next number; the step on screen takes it on, and so does the saved set of the same name.
    private void ContinueNumbers(BatchSet ran, IReadOnlyList<BatchStep> live)
    {
        bool moved = false;
        for (int i = 0; i < live.Count; i++)
        {
            if (live[i].Kind != BatchStepKind.Bates || live[i].Start == ran.Steps[i].Start) continue;
            live[i].Start = ran.Steps[i].Start;
            moved = true;
        }
        if (!moved) return;
        ShowRows(StepList.SelectedIndex);
        ShowEditor();
        var saved = _store.Load().FirstOrDefault(s => string.Equals(s.Name, _set.Name, StringComparison.CurrentCultureIgnoreCase));
        if (saved is null || saved.Steps.Count != _set.Steps.Count) return;
        for (int i = 0; i < saved.Steps.Count; i++)
        {
            if (saved.Steps[i].Kind == BatchStepKind.Bates && _set.Steps[i].Kind == BatchStepKind.Bates) saved.Steps[i].Start = _set.Steps[i].Start;
        }
        _store.Save(saved);
    }

    private void BrowseWatch_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = Loc.T("Folder to watch"), InitialDirectory = _set.WatchFolder };
        if (dialog.ShowDialog() != true) return;
        _set.WatchFolder = dialog.FolderName;
        RecheckWatch();
        ShowWatch();
    }

    private void Watch_Click(object sender, RoutedEventArgs e)
    {
        if (WatchToggle.IsChecked != true)
        {
            StopWatching();
            ShowWatch();
            return;
        }
        if (WatchProblem() is { } problem)
        {
            WatchToggle.IsChecked = false;
            Host?.ShowProblem(problem);
            return;
        }
        if (!StartWatching()) WatchToggle.IsChecked = false;
    }

    // The steps or folders changed while watching: stop if watching no longer makes sense, follow the folder if it moved.
    private void RecheckWatch()
    {
        if (_watcher is null) return;
        if (WatchProblem() is { } problem)
        {
            StopWatching();
            Host?.ShowProblem(problem);
        }
        else if (!SameFolder(_set.WatchFolder, _watchedFolder))
        {
            StopWatching();
            StartWatching();
        }
    }

    private Problem? WatchProblem()
    {
        if (_set.Steps.Count == 0) return new Problem(Loc.T("No steps"), Loc.T("Add at least one step, then watch the folder."));
        if (!Directory.Exists(_set.WatchFolder)) return new Problem(Loc.T("No folder to watch"), Loc.T("Choose an existing folder to watch."));
        if (_set.OutputFolder.Length == 0) return new Problem(Loc.T("No results folder"), Loc.T("Choose where the results go, then watch the folder."));
        if (SameFolder(_set.OutputFolder, _set.WatchFolder)) return new Problem(Loc.T("Same folder"), Loc.T("Choose a results folder other than the watched one, or the results would run again."));
        return null;
    }

    private static bool SameFolder(string a, string b) =>
        string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(a)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(b)), StringComparison.OrdinalIgnoreCase);

    private bool StartWatching()
    {
        FolderWatcher watcher;
        try
        {
            watcher = new FolderWatcher(_set.WatchFolder);
        }
        catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException)
        {
            Host?.ShowProblem(new Problem(Loc.T("Folder cannot be watched"), Loc.T("Windows does not let Lazy PDF watch this folder. Choose another.")));
            return false;
        }
        _watchCancel = new CancellationTokenSource();
        _watchedFolder = _set.WatchFolder;
        _watcher = watcher;
        watcher.Found += path => Dispatcher.BeginInvoke(() =>
        {
            if (!ReferenceEquals(_watcher, watcher)) return;
            _arrived.Enqueue(path);
            _ = DrainAsync();
        });
        watcher.Failed += () => Dispatcher.BeginInvoke(() =>
        {
            if (!ReferenceEquals(_watcher, watcher)) return;
            StopWatching();
            AddLog(new BatchResult(_watchedFolder, null, false, Loc.T("Watching stopped"), Loc.T("The folder cannot be watched any more. Check that it is there, then switch watching on again.")));
        });
        ShowWatch();
        return true;
    }

    internal void StopWatching()
    {
        _watchCancel?.Cancel();
        _watchCancel = null;
        _watcher?.Dispose();
        _watcher = null;
        _arrived.Clear();
        ShowWatch();
    }

    private async Task DrainAsync()
    {
        if (_draining) return;
        _draining = true;
        try
        {
            while (_arrived.TryDequeue(out var path) && _watchCancel is { } cancel)
            {
                var result = await RunOneAsync(path, _set.Copy(), _set.Steps.ToList(), ++_watched, cancel.Token);
                AddLog(result);
                Host?.SetStatus(result.Ok ? Loc.T("Ran {0}", Path.GetFileName(path)) : Loc.T("{0} failed", Path.GetFileName(path)));
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            _draining = false;
        }
    }
}
