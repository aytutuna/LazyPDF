namespace LazyPDF.Core;

/// <summary>
/// "Clean for sharing". <see cref="Scan"/> lists what the file holds; <see cref="Run"/> writes a new
/// file without the chosen kinds. The file is always rewritten, so earlier versions and
/// unreferenced objects go with it, and the document is not changed. Signatures do not survive, and
/// neither do their values, appearances, /DSS and /Perms. The output keeps the encryption of the
/// input unless <see cref="SanitizeOptions.KeepEncryption"/> is off or a handler is given.
/// </summary>
public sealed class PdfSanitizer(PdfDocument document)
{
    private static readonly SanitizeOptions Everything = new() { InvisibleText = true };

    /// <summary>What was found, each with a count, in the order of <see cref="SanitizeItem"/>.</summary>
    public IReadOnlyList<SanitizeFinding> Scan()
    {
        using var working = PdfDocument.Open(document.SaveRewrite());
        var (found, _) = Apply(working, Everything);
        return Findings(found);
    }

    public SanitizeResult Run(SanitizeOptions options)
    {
        using var working = PdfDocument.Open(document.SaveRewrite());
        var (found, stripped) = Apply(working, options);
        var removed = new Dictionary<SanitizeItem, int>();
        foreach (var (item, count) in found)
        {
            if (!IsRemoved(item, options)) continue;
            removed[item] = item == SanitizeItem.InvisibleText ? stripped : count;
        }
        var kept = found.Where(f => !removed.ContainsKey(f.Key)).ToDictionary();
        if (removed.TryGetValue(SanitizeItem.InvisibleText, out int shows) && found[SanitizeItem.InvisibleText] > shows) kept[SanitizeItem.InvisibleText] = found[SanitizeItem.InvisibleText] - shows;
        var security = options.Security ?? (options.KeepEncryption ? document.Security : null);
        // The keys of the older handlers are made from the first /ID, so a handler taken over from the input keeps the id it was made with.
        bool inherited = security is not null && ReferenceEquals(security, document.Security);
        byte[]? id = inherited && security is { Revision: < 5 } ? document.FirstId : options.DocumentId ?? (inherited ? document.FirstId : null);
        byte[] bytes = working.SaveRewrite(new PdfSaveOptions(false, security, id));
        return new SanitizeResult(bytes, Findings(removed), Findings(kept), document.Length, bytes.Length);
    }

    private static List<SanitizeFinding> Findings(IReadOnlyDictionary<SanitizeItem, int> counts) =>
        [.. counts.Where(c => c.Value > 0).OrderBy(c => c.Key).Select(c => new SanitizeFinding(c.Key, c.Value))];

    private static bool IsRemoved(SanitizeItem item, SanitizeOptions o) => item switch
    {
        SanitizeItem.JavaScript => o.JavaScript,
        SanitizeItem.LaunchActions => o.LaunchActions,
        SanitizeItem.EmbeddedFiles => o.EmbeddedFiles,
        SanitizeItem.HiddenLayers => o.HiddenLayers,
        SanitizeItem.InvisibleText => o.InvisibleText,
        SanitizeItem.Comments => o.Comments,
        SanitizeItem.FormData => o.FormData,
        SanitizeItem.Metadata => o.Metadata,
        SanitizeItem.PieceInfo => o.PieceInfo,
        SanitizeItem.Thumbnails => o.Thumbnails,
        SanitizeItem.SearchIndexes => o.SearchIndexes,
        SanitizeItem.ExternalLinks => o.ExternalLinks,
        SanitizeItem.FilePaths => o.FilePaths,
        SanitizeItem.PreviousVersions or SanitizeItem.Signatures => true,
        _ => false,
    };

    // Counts everything and removes what the options choose; returns the counts and the number of invisible shows taken out.
    private (Dictionary<SanitizeItem, int> Found, int Stripped) Apply(PdfDocument working, SanitizeOptions o)
    {
        var found = new Dictionary<SanitizeItem, int> { [SanitizeItem.Signatures] = SanitizeSignatures.Strip(working) };
        var text = new SanitizeText(working);
        var (hidden, invisible) = text.Count();
        found[SanitizeItem.HiddenText] = hidden;
        found[SanitizeItem.InvisibleText] = invisible;
        int stripped = o.InvisibleText && invisible > 0 ? text.Strip() : 0;

        found[SanitizeItem.HiddenLayers] = new SanitizeLayers(working).Run(o.HiddenLayers);
        var (scripts, launch, uri) = SanitizeActions.Run(working, o.JavaScript, o.LaunchActions, o.ExternalLinks);
        found[SanitizeItem.JavaScript] = scripts;
        found[SanitizeItem.LaunchActions] = launch;
        found[SanitizeItem.ExternalLinks] = uri;
        found[SanitizeItem.EmbeddedFiles] = SanitizeData.EmbeddedFiles(working, o.EmbeddedFiles);
        found[SanitizeItem.Comments] = SanitizeData.Comments(working, o.Comments);
        found[SanitizeItem.FormData] = SanitizeData.FormData(working, o.FormData);
        found[SanitizeItem.Metadata] = SanitizeData.Metadata(working, o.Metadata);
        found[SanitizeItem.PieceInfo] = SanitizeData.PieceInfo(working, o.PieceInfo);
        found[SanitizeItem.Thumbnails] = SanitizeData.Thumbnails(working, o.Thumbnails);
        found[SanitizeItem.SearchIndexes] = SanitizeData.SearchIndexes(working, o.SearchIndexes);
        found[SanitizeItem.FilePaths] = SanitizeData.FilePaths(working, o.FilePaths);
        found[SanitizeItem.PreviousVersions] = Math.Max(0, document.SectionOffsets.Count - (document.WasLinearized ? 2 : 1));
        return (found, stripped);
    }
}
