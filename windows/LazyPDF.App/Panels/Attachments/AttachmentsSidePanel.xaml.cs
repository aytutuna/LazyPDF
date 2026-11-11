using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using LazyPDF.App.Tools.Comment;
using LazyPDF.App.Tools.EditContent;
using LazyPDF.Core;
using Microsoft.Win32;

namespace LazyPDF.App.Panels.Attachments;

/// <summary>One line of the list.</summary>
public sealed class AttachmentRow(PdfAttachment item, string pageText)
{
    public PdfAttachment Item { get; } = item;

    public string Name => string.IsNullOrEmpty(Item.FileName) ? Item.Name : Item.FileName;

    public string Details => string.Join(" · ", new[] { Item.Size is { } size ? Size(size) : null, pageText, Item.Description }.Where(s => !string.IsNullOrEmpty(s)));

    public string Summary => Details.Length == 0 ? Name : Name + ", " + Details;

    private static string Size(long bytes) => bytes switch
    {
        < 1024 => Loc.T("{0} bytes", bytes),
        < 1024 * 1024 => Loc.T("{0} KB", Math.Round(bytes / 1024.0, 1)),
        _ => Loc.T("{0} MB", Math.Round(bytes / 1048576.0, 1)),
    };
}

/// <summary>The files carried inside the PDF: open one, or save it. A file that could run as a program can only be saved.</summary>
public partial class AttachmentsSidePanel : ToolPanel
{
    public AttachmentsSidePanel() => InitializeComponent();

    private const long MaxSize = 100 * 1024 * 1024;

    private static string OpenedFolder => AppFolders.OpenedAttachments;

    /// <summary>Removes the copies made to open attachments, which hold the file decrypted. One a program still has open stays.</summary>
    public static void DeleteOpenedCopies()
    {
        if (!Directory.Exists(OpenedFolder)) return;
        foreach (string copy in Directory.EnumerateDirectories(OpenedFolder))
        {
            try { Directory.Delete(copy, recursive: true); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    protected override void OnAttach()
    {
        Tab!.Changed += Tab_Changed;
        Build();
        UpdateEnabled();
    }

    protected override void OnDetach()
    {
        Tab!.Changed -= Tab_Changed;
        Files.ItemsSource = null;
    }

    private void Tab_Changed(object? sender, EventArgs e) => Build();

    private void Build()
    {
        var list = PdfAttachments.List(Tab!.Document);
        Files.ItemsSource = list.Select(a => new AttachmentRow(a, a.PageIndex is { } page ? Loc.T("Page {0}", page + 1) : "")).ToList();
        Empty.Visibility = list.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        Note.Visibility = Visibility.Collapsed;
    }

    private void Files_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        OpenButton.IsEnabled = SaveButton.IsEnabled = Files.SelectedItem is not null;
        UpdateEnabled();
    }

    private void UpdateEnabled()
    {
        bool editable = Clearance.Refusal(Tab!.Document) is null;
        AddButton.IsEnabled = editable;
        DeleteButton.IsEnabled = editable && Files.SelectedItem is not null;
    }

    private void Files_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != System.Windows.Input.Key.Delete || System.Windows.Input.Keyboard.Modifiers != System.Windows.Input.ModifierKeys.None) return;
        Delete_Click(sender, e);
        e.Handled = true;
    }

    // Null when the file may be changed now; otherwise the change waits or is refused, with the reason shown.
    private (DocumentTab Tab, IToolHost Host)? Editable(Action again)
    {
        if (Tab is not { } tab || Host is not { } host || MarkWork.Running) return null;
        if (Clearance.Refusal(tab.Document) is { } problem)
        {
            host.ShowProblem(problem);
            return null;
        }
        return MarkWork.Cautioned(tab, host, again) ? null : (tab, host);
    }

    private async void Add_Click(object sender, RoutedEventArgs e)
    {
        if (Editable(() => Add_Click(sender, e)) is not var (tab, host)) return;
        var dialog = new OpenFileDialog { Multiselect = true, Filter = Loc.T("All files") + "|*.*" };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        var files = new List<(string Name, byte[] Data, DateTime Modified)>();
        string name = "";
        try
        {
            foreach (string path in dialog.FileNames)
            {
                name = System.IO.Path.GetFileName(path);
                if (new FileInfo(path).Length > MaxSize)
                {
                    host.ShowProblem(new Problem(Loc.T("File too large"), Loc.T("{0} is over 100 MB, so it was not added.", name)));
                    continue;
                }
                files.Add((AttachmentFiles.SafeName(name), await File.ReadAllBytesAsync(path), File.GetLastWriteTimeUtc(path)));
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            host.ShowProblem(Problems.Open(error, name));
            return;
        }
        if (files.Count == 0 || !ReferenceEquals(Tab, tab) || MarkWork.Running) return;
        if (await WorkAsync(tab, host, Loc.T("Adding files"), () =>
        {
            foreach (var (safe, data, modified) in files) PdfAttachments.Add(tab.Document, safe, data, null, null, null, modified);
        }) && MarkWork.Commit(tab, host, Loc.T("Add attachment")))
        {
            host.SetStatus(Loc.Plural(files.Count, "{0} file attached.", "{0} files attached."));
        }
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (Files.SelectedItem is not AttachmentRow row || Editable(() => Delete_Click(sender, e)) is not var (tab, host)) return;
        if (!PdfAttachments.Remove(tab.Document, row.Item))
        {
            host.SetStatus(Loc.T("That attachment is no longer in the file."));
            return;
        }
        if (MarkWork.Commit(tab, host, Loc.T("Delete attachment"))) host.SetStatus(Loc.T("Attachment deleted."));
    }

    // Changes the file off the UI thread; anything but a clean finish (a stop, a failure, another tab) puts it back as it was.
    private async Task<bool> WorkAsync(DocumentTab tab, IToolHost host, string text, Action work)
    {
        bool done = false;
        MarkWork.Running = true;
        try
        {
            await host.RunBusyAsync(text, async ct =>
            {
                try
                {
                    await Task.Run(() =>
                    {
                        ct.ThrowIfCancellationRequested();
                        work();
                    });
                    ct.ThrowIfCancellationRequested();
                    done = true;
                }
                catch
                {
                    tab.Session.Discard();
                    throw;
                }
            });
        }
        finally
        {
            MarkWork.Running = false;
        }
        if (done && !ReferenceEquals(Tab, tab))
        {
            tab.Session.Discard();
            return false;
        }
        return done;
    }

    private void Files_MouseDoubleClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source && ItemsControl.ContainerFromElement(Files, source) is ListBoxItem) Open_Click(sender, e);
    }

    private void Tell(string text)
    {
        Note.Text = text;
        Note.Visibility = Visibility.Visible;
    }

    private byte[]? Read(AttachmentRow row)
    {
        try
        {
            return PdfAttachments.Extract(Tab!.Document, row.Item);
        }
        catch (Exception error) when (error is PdfReadException or InvalidOperationException)
        {
            Tell(Loc.T("This attachment could not be read."));
            return null;
        }
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        if (Files.SelectedItem is not AttachmentRow row) return;
        string name = AttachmentFiles.SafeName(row.Name);
        if (AttachmentFiles.CouldRun(name))
        {
            Tell(Loc.T("This file could run as a program. Save it instead."));
            return;
        }
        var tab = Tab;
        var document = tab!.Document;
        // The question stays on the info bar after the panel is detached or the row is undone.
        // Every commit, undo and redo brings a new document, and the row's object number may now be another file.
        Host!.ShowNotice(Loc.T("Open this attachment?"), Loc.T("{0} came inside this PDF. Open it only if you trust where the PDF came from.", row.Name),
            new NoticeAction(Loc.T("Open"), () =>
            {
                if (!ReferenceEquals(Tab, tab)) return;
                if (ReferenceEquals(tab!.Document, document)) OpenCopy(row, name);
                else Tell(Loc.T("The file changed meanwhile. Try again."));
            }));
    }

    private void OpenCopy(AttachmentRow row, string name)
    {
        if (Read(row) is not { } bytes) return;
        try
        {
            string folder = System.IO.Path.Combine(OpenedFolder, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            string path = System.IO.Path.Combine(folder, name.Length > 0 ? name : "attachment");
            File.WriteAllBytes(path, bytes);
            MarkFromInternet(path);
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            Note.Visibility = Visibility.Collapsed;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            Tell(Loc.T("This attachment could not be opened."));
        }
    }

    // Zone 3 makes Office open the copy in Protected View and SmartScreen check it.
    private static void MarkFromInternet(string path)
    {
        try
        {
            File.WriteAllText(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=3\r\n");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or NotSupportedException) { }
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        if (Files.SelectedItem is not AttachmentRow row) return;
        var dialog = new SaveFileDialog { FileName = AttachmentFiles.SafeName(row.Name), Title = Loc.T("Save attachment") };
        if (dialog.ShowDialog() != true || Read(row) is not { } bytes) return;
        try
        {
            File.WriteAllBytes(dialog.FileName, bytes);
            Note.Visibility = Visibility.Collapsed;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Tell(Loc.T("The attachment could not be saved. Check the folder and try again."));
        }
    }
}
