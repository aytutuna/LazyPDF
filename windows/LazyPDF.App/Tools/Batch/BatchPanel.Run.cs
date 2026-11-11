// The files, the results folder, running the steps and the watched folder.

using System.IO.Enumeration;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using Microsoft.Win32;

namespace LazyPDF.App.Tools.Batch;

public partial class BatchPanel
{
    private const int MaxFiles = 5000;

    // One file at a time, so a run and the watcher never share the Bates numbers or the output names.
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Queue<string> _arrived = new();
    private readonly Dictionary<string, string> _roots = new(StringComparer.OrdinalIgnoreCase);
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

    private void Stop_Click(object sender, RoutedEventArgs e) => _set.StopOnError = StopBox.IsChecked == true;

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

    private async void AddFolder_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = Loc.T("Folder of PDFs") };
        if (dialog.ShowDialog() != true) return;
        AddFiles(await PdfsInAsync(dialog.FolderName, IncludeSubfolders.IsChecked == true), dialog.FolderName);
    }

    private void Panel_DragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    private async void Panel_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        _folderFailed = false;
        bool added = false;
        foreach (var folder in paths.Where(Directory.Exists))
        {
            var inside = await PdfsInAsync(folder, IncludeSubfolders.IsChecked == true);
            AddFiles(inside, folder);
            added |= inside.Count > 0;
        }
        var singles = paths.Where(p => !Directory.Exists(p) && string.Equals(System.IO.Path.GetExtension(p), ".pdf", StringComparison.OrdinalIgnoreCase)).ToList();
        AddFiles(singles);
        if (!added && singles.Count == 0 && !_folderFailed) Host?.SetStatus(Loc.T("Only PDF files can be added."));
    }

    internal async Task<List<string>> PdfsInAsync(string folder, bool recurse)
    {
        string? results = _set.OutputFolder.Length > 0 ? Path.TrimEndingDirectorySeparator(Path.GetFullPath(_set.OutputFolder)) : null;
        try
        {
            List<string>? found = null;
            bool leftOut = false;
            if (Host is null) found = Walk(folder, recurse, results, out leftOut, CancellationToken.None);
            else if (_running) (found, leftOut) = await Task.Run(() => (Walk(folder, recurse, results, out bool skipped, CancellationToken.None), skipped)); // the run owns the host's busy state
            else await Host.RunBusyAsync(Loc.T("Looking for PDFs"), async token =>
            {
                var walked = await Task.Run(() => (Files: Walk(folder, recurse, results, out bool skipped, token), Skipped: skipped));
                (found, leftOut) = (walked.Files, walked.Skipped);
            });
            if (found is null)
            {
                _folderFailed = true;
                return [];
            }
            if (found.Count > MaxFiles)
            {
                found.RemoveAt(MaxFiles);
                Host?.SetStatus(Loc.T("Only the first 5000 files were added."));
            }
            else if (leftOut)
            {
                _folderFailed = true;
                Host?.SetStatus(Loc.T("The results folder was left out."));
            }
            found.Sort((a, b) => string.Compare(Path.GetRelativePath(folder, a), Path.GetRelativePath(folder, b), StringComparison.CurrentCultureIgnoreCase));
            return found;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            _folderFailed = true;
            var leaf = Path.GetFileName(folder.TrimEnd('\\', '/'));
            Host?.ShowProblem(new Problem(Loc.T("Folder not read"),
                Loc.T("{0} could not be read. Check that it is there and that you may open it.", leaf.Length > 0 ? leaf : folder)));
            return [];
        }
    }

    // Links to folders are not followed so a folder that points back up cannot loop, and the results folder is left out so results never run again.
    internal static List<string> Walk(string folder, bool recurse, string? results, out bool leftOut, CancellationToken token)
    {
        bool skipped = false;
        var options = new EnumerationOptions { RecurseSubdirectories = recurse, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System };
        var files = new FileSystemEnumerable<string>(folder, (ref FileSystemEntry e) => e.ToFullPath(), options)
        {
            ShouldIncludePredicate = (ref FileSystemEntry e) =>
            {
                token.ThrowIfCancellationRequested();
                if (e.IsDirectory || !e.FileName.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) return false;
                bool inResults = results is not null && e.ToFullPath().StartsWith(results + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
                skipped |= inResults;
                return !inResults;
            },
            ShouldRecursePredicate = (ref FileSystemEntry e) =>
            {
                if ((e.Attributes & FileAttributes.ReparsePoint) != 0) return false;
                bool inResults = results is not null && string.Equals(e.ToFullPath(), results, StringComparison.OrdinalIgnoreCase);
                skipped |= inResults;
                return !inResults;
            },
        };
        var found = files.Take(MaxFiles + 1).ToList();
        leftOut = skipped;
        return found;
    }

    internal void AddFiles(IEnumerable<string> paths, string? root = null)
    {
        foreach (var path in paths)
        {
            if (!_known.Add(path)) continue;
            _files.Add(path);
            if (root is not null) _roots[path] = root;
        }
        ShowFiles();
    }

    private void RemoveFile_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not FileRow row) return;
        _files.Remove(row.Path);
        _known.Remove(row.Path);
        _roots.Remove(row.Path);
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
        if (BatchRunner.Check(_set) is { } refused)
        {
            Host?.ShowProblem(refused);
            return;
        }
        var set = _set.Copy();
        var live = _set.Steps.ToList();
        var files = _files.ToList();
        int failed = 0;
        bool cancelled = false;
        string? stoppedAt = null;
        int rest = 0;
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
                        result = await RunOneAsync(files[i], set, live, i + 1, token, RelativeDir(files[i]));
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
                        _roots.Remove(files[i]);
                    }
                    else
                    {
                        failed++;
                        if (set.StopOnError && i + 1 < files.Count)
                        {
                            stoppedAt = Path.GetFileName(files[i]);
                            rest = files.Count - i - 1;
                            return;
                        }
                    }
                }
            });
        }
        finally
        {
            _running = false;
            ShowFiles();
        }
        if (stoppedAt is not null)
        {
            Host?.SetStatus(Loc.T("Stopped at {0}. {1}", stoppedAt, Loc.Plural(rest, "{0} file was not run.", "{0} files were not run.")));
            return;
        }
        Host?.SetStatus(cancelled ? Loc.T("Cancelled.") : failed == 0 ? Loc.T("All files done") : Loc.Plural(failed, "{0} file failed", "{0} files failed"));
    }

    // A watched folder and a run go on while another tool is open, and they need the password.
    private void Panel_Unloaded(object sender, RoutedEventArgs e)
    {
        if (_watcher is null && !_running) ClearPassword();
    }

    internal void ClearPassword() => OpenPassword.Clear();

    private string RelativeDir(string path)
    {
        if (!_roots.TryGetValue(path, out var root)) return "";
        var dir = System.IO.Path.GetRelativePath(root, System.IO.Path.GetDirectoryName(path)!);
        return dir == "." ? "" : dir;
    }

    // <paramref name="live"/> are the steps on screen that <paramref name="set"/> was copied from, in the same order.
    internal async Task<BatchResult> RunOneAsync(string path, BatchSet set, IReadOnlyList<BatchStep> live, int number, CancellationToken token, string relativeDir = "")
    {
        await _gate.WaitAsync(token);
        try
        {
            string password = OpenPassword.Password;
            for (int i = 0; i < live.Count; i++)
            {
                if (live[i].Kind == BatchStepKind.Bates) set.Steps[i].Start = live[i].Start;
            }
            var result = await Task.Run(() => Runner.RunAsync(path, set, number, DateTimeOffset.Now, token, relativeDir, password), token);
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
        if (BatchRunner.Check(_set) is { } refused) return refused;
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
