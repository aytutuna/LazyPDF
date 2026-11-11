// The Home tab: the files opened last, the tiles for the jobs people come for, and what Lazy PDF
// offers after a crash.

using LazyPDF.App.Documents;
using LazyPDF.App.Services;
using LazyPDF.App.Tools;
using LazyPDF.Core;

namespace LazyPDF.App;

/// <summary>A file in the recent list, with the words the Home tab shows for it.</summary>
public sealed record RecentItem(string Path, string Name, string Folder, string Opened, bool Pinned);

/// <summary>A job on the Home tab. <paramref name="Reason"/> says why it cannot be started, null when it can.</summary>
public sealed record HomeTile(string Id, string Title, string Glyph, string Description, bool Available, string? Reason)
{
    /// <summary>The description, and why the tile cannot be started when it cannot, for the tooltip and screen readers.</summary>
    public string HelpText => Reason is null ? Description : Loc.T("{0} Not available: {1}", Description, Reason);
}

public sealed partial class AppViewModel
{
    public const string OpenTile = "open";
    public const string CreateTile = "create";
    public const string ScanTile = "scan";
    public const string BatchTile = "batch";

    /// <summary>The tools behind the tiles that are tools: tile id, tool id.</summary>
    private static readonly (string Tile, string Tool)[] ToolTiles =
    [
        ("combine", "combine"), ("compress", "optimize"), ("protect", "protect"), ("sign", "fillsign"),
        ("form", "forms"), ("edit", "editcontent"), ("export", "export"),
    ];

    public IReadOnlyList<RecentItem> Recent { get; private set; }

    /// <summary>What a crash left behind; null when there is nothing to offer.</summary>
    public IReadOnlyList<RecoveryEntry>? RecoveryOffer { get; private set; }

    public IReadOnlyList<HomeTile> Tiles
    {
        get
        {
            bool hasDocument = _lastDocument is not null;
            string needFile = Loc.T("Open a file first");
            HomeTile ForTool(string id, string title, string glyph, string description) =>
                new(id, title, glyph, description, hasDocument, hasDocument ? null : needFile);

            // Lazy Scan is a separate app: its tile is there only when it is.
            HomeTile[] scan = _sisters.LazyScanInstalled
                ? [new(ScanTile, Loc.T("Lazy Scan"), "", Loc.T("Scan paper into a PDF with Lazy Scan."), true, null)]
                : [];

            return
            [
                new(OpenTile, Loc.T("Open"), "\uE8E5", Loc.T("Open a PDF, a picture or a text file."), true, null),
                new(CreateTile, Loc.T("Create"), "\uE8B9", Loc.T("Make a PDF from blank pages, pictures, text or the clipboard."), true, null),
                ForTool("combine", Loc.T("Combine"), "\uE8F4", Loc.T("Join files into a new one, or split this one.")),
                ForTool("compress", Loc.T("Make smaller"), "\uE9D9", Loc.T("Make the file smaller.")),
                ForTool("protect", Loc.T("Protect"), "\uE72E", Loc.T("Set a password and decide what others may do.")),
                ForTool("sign", Loc.T("Sign"), "\uE76D", Loc.T("Sign the file with your name.")),
                ForTool("form", Loc.T("Fill a form"), "\uE8D2", Loc.T("Fill in the fields of a form.")),
                ForTool("edit", Loc.T("Edit"), "\uE70F", Loc.T("Change the words and pictures on a page.")),
                .. scan,
                ForTool("export", Loc.T("Export"), "\uE8AD", Loc.T("Save as Word, Excel, PowerPoint, HTML, text or pictures.")),
                new(BatchTile, Loc.T("Batch"), "", Loc.T("Do the same to every file in a folder."), true, null),
            ];
        }
    }

    /// <summary>
    /// Starts the job behind a tile: a tool opens on the document last in use, Scan starts Lazy Scan. Open is the
    /// window's, since it needs the file dialog. A tile that cannot be started says why in the status line.
    /// </summary>
    public void StartTile(string id)
    {
        if (id == ScanTile)
        {
            if (_sisters.LazyScanInstalled && !_sisters.OpenLazyScan())
                ShowProblem(new Problem(Loc.T("Lazy Scan did not start"), Loc.T("Windows could not open Lazy Scan. Open it from the Start menu, or reinstall it.")));
            return;
        }
        var tool = ToolTiles.FirstOrDefault(t => t.Tile == id).Tool;
        if (tool is null) return;
        if (_lastDocument is null || !Strip.Contains(_lastDocument))
        {
            SetStatus(Tiles.Single(t => t.Id == id).HelpText);
            return;
        }
        _activeTab = _lastDocument;
        _activeToolId = tool;
        NotifyAll();
    }

    /// <summary>Takes a file out of the recent list.</summary>
    public void ForgetRecent(string path)
    {
        _recentFiles.Remove(path);
        Recent = BuildRecent();
        NotifyAll();
    }

    public void SetPinned(string path, bool pinned)
    {
        _recentFiles.SetPinned(path, pinned);
        Recent = BuildRecent();
        NotifyAll();
    }

    public void ClearRecent()
    {
        _recentFiles.Clear();
        Recent = BuildRecent();
        NotifyAll();
    }

    private IReadOnlyList<RecentItem> BuildRecent() =>
        [.. _recentFiles.Load().Select(f => new RecentItem(
            f.Path, System.IO.Path.GetFileName(f.Path), FolderName(f.Path), When(f.Opened), f.Pinned))];

    private static string FolderName(string path)
    {
        string folder = System.IO.Path.GetDirectoryName(path) ?? "";
        string leaf = System.IO.Path.GetFileName(folder);
        return leaf.Length > 0 ? leaf : folder;
    }

    private static string When(DateTimeOffset opened)
    {
        var days = (DateTime.Now.Date - opened.LocalDateTime.Date).Days;
        return days switch
        {
            <= 0 => Loc.T("Today"),
            1 => Loc.T("Yesterday"),
            < 7 => opened.LocalDateTime.ToString("dddd"),
            _ => opened.LocalDateTime.ToString("d"),
        };
    }

    /// <summary>Looks in the recovery folder: anything there is what a crash left, because a document closed on purpose removes its copy.</summary>
    public void CheckRecovery()
    {
        _recovery.Sweep();
        var found = _recovery.Abandoned();
        RecoveryOffer = found.Count == 0 ? null : found;
        NotifyAll();
    }

    /// <summary>Opens what <see cref="RecoveryOffer"/> lists, as documents with unsaved changes.</summary>
    public async Task RestoreAsync()
    {
        var offer = RecoveryOffer;
        RecoveryOffer = null;
        NotifyAll();
        foreach (var entry in offer ?? [])
        {
            byte[] bytes;
            try
            {
                bytes = await File.ReadAllBytesAsync(entry.PdfPath);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                ShowProblem(Problems.Open(e, entry.Meta.Title));
                continue;
            }
            // A file that is open already comes back as a copy that needs a name, not as a second tab on the file.
            string? path = entry.Meta.OriginalPath is { } original && TabOf(original) is null ? original : null;
            DiskStamp? stamp = entry.Meta.OriginalWrite == default ? null : new DiskStamp(entry.Meta.OriginalWrite, entry.Meta.OriginalLength);
            bool readOnly = false;
            try
            {
                readOnly = path is not null && File.Exists(path) && new FileInfo(path).IsReadOnly;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
            var source = new OpenSource(bytes, path, entry.Meta.Title, Made: false, Stamp: path is null ? null : stamp, ReadOnly: readOnly);
            await OpenAsync(new PendingOpen(source, entry.Id), password: null, certificate: null);
        }
    }

    public void DiscardRecovery()
    {
        foreach (var entry in RecoveryOffer ?? []) _recovery.Delete(entry.Id);
        RecoveryOffer = null;
        NotifyAll();
    }
}
