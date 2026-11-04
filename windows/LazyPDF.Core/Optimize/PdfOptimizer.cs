namespace LazyPDF.Core;

/// <summary>
/// Makes a file smaller by a full rewrite (<see cref="PdfDocument.SaveRewrite"/>) with the steps
/// the options choose. The document is not changed: the steps run on a copy made from a plain
/// rewrite, and the result is never larger than that rewrite. Signatures do not survive.
/// </summary>
public sealed class PdfOptimizer(PdfDocument document, IImageCodec? codec = null)
{
    /// <summary>The space audit of the file and the steps <paramref name="options"/> would run.</summary>
    public OptimizePlan Plan(OptimizeOptions options)
    {
        var steps = new List<OptimizeStepKind> { OptimizeStepKind.RemoveUnreferenced };
        void Add(bool on, OptimizeStepKind kind)
        {
            if (on) steps.Add(kind);
        }
        Add(options.StripThumbnails, OptimizeStepKind.StripThumbnails);
        Add(options.StripPieceInfo, OptimizeStepKind.StripPieceInfo);
        Add(options.StripPrivateData, OptimizeStepKind.StripPrivateData);
        Add(options.PruneResources, OptimizeStepKind.PruneResources);
        Add(options.RemoveDuplicates, OptimizeStepKind.RemoveDuplicates);
        Add(options.SubsetFonts, OptimizeStepKind.SubsetFonts);
        Add(options.Grayscale, OptimizeStepKind.Grayscale);
        Add(options.BilevelTolerance >= 0, OptimizeStepKind.BilevelImages);
        Add(options.ImageDpi > 0, OptimizeStepKind.DownsampleImages);
        Add(options.RecompressStreams, OptimizeStepKind.RecompressStreams);
        Add(options.ConvertOldFilters, OptimizeStepKind.ConvertOldFilters);
        Add(options.ObjectStreams, OptimizeStepKind.ObjectStreams);
        return new OptimizePlan(Audit(), steps);
    }

    public SpaceAudit Audit() => new PdfSpaceAudit(document).Run();

    public OptimizeResult Run(OptimizeOptions options)
    {
        var audit = Audit();
        byte[] plain = document.SaveRewrite();
        using var working = PdfDocument.Open(plain);
        var results = new List<OptimizeStepResult> { new(OptimizeStepKind.RemoveUnreferenced, UnreferencedCount()) };
        var notes = new List<string>();
        void Did(OptimizeStepKind kind, int count) => results.Add(new OptimizeStepResult(kind, count));

        if (options.StripThumbnails) Did(OptimizeStepKind.StripThumbnails, OptimizeStrip.Thumbnails(working));
        if (options.StripPieceInfo) Did(OptimizeStepKind.StripPieceInfo, OptimizeStrip.PieceInfo(working));
        if (options.StripPrivateData) Did(OptimizeStepKind.StripPrivateData, OptimizeStrip.PrivateData(working));
        if (options.PruneResources) Did(OptimizeStepKind.PruneResources, new OptimizeResources(working).Run());
        int merged = options.RemoveDuplicates ? OptimizeDuplicates.Run(working) : 0;
        if (options.SubsetFonts)
        {
            Did(OptimizeStepKind.SubsetFonts, new OptimizeFonts(working).Run(out bool partial));
            if (partial) notes.Add(OptimizeText.LeftPartialFonts);
        }
        if (options.Grayscale)
        {
            var gray = new OptimizeGray(working, codec, options.JpegQuality);
            gray.Run();
            Did(OptimizeStepKind.Grayscale, gray.Streams + gray.Images);
            if (gray.Left > 0) notes.Add(OptimizeText.LeftColor);
            if (gray.NeedsCodec) notes.Add(OptimizeText.NeedsCodec);
        }
        if (options.BilevelTolerance >= 0 || options.ImageDpi > 0)
        {
            var images = new OptimizeImages(working, options, codec);
            images.Run();
            if (options.BilevelTolerance >= 0) Did(OptimizeStepKind.BilevelImages, images.Bilevel);
            if (options.ImageDpi > 0) Did(OptimizeStepKind.DownsampleImages, images.Downsampled);
            if (images.NeedsCodec && !notes.Contains(OptimizeText.NeedsCodec)) notes.Add(OptimizeText.NeedsCodec);
        }
        var (recompressed, converted) = OptimizeStreams.Run(working, options.RecompressStreams, options.ConvertOldFilters);
        if (options.RecompressStreams) Did(OptimizeStepKind.RecompressStreams, recompressed);
        if (options.ConvertOldFilters) Did(OptimizeStepKind.ConvertOldFilters, converted);
        if (options.RemoveDuplicates) Did(OptimizeStepKind.RemoveDuplicates, merged + OptimizeDuplicates.Run(working));

        var best = Save(working, options, false);
        if (options.ObjectStreams && document.PdfAPart != 1)
        {
            var packed = Save(working, options, true);
            if (packed.Length < best.Length) best = packed;
            Did(OptimizeStepKind.ObjectStreams, ReferenceEquals(best, packed) ? 1 : 0);
        }
        // A plain rewrite is the floor, unless the file was asked to change its look or to be encrypted or given an id.
        if (best.Length > plain.Length && !options.Grayscale && options.Security is null && options.DocumentId is null) best = plain;
        return new OptimizeResult(best, document.Length, best.Length, audit, results, notes);
    }

    private static byte[] Save(PdfDocument working, OptimizeOptions options, bool objectStreams) =>
        working.SaveRewrite(new PdfSaveOptions(objectStreams, options.Security, options.DocumentId));

    private int UnreferencedCount()
    {
        var reached = new HashSet<int>();
        var queue = new Queue<PdfObject?>([document.Trailer]);
        while (queue.Count > 0)
        {
            foreach (var reference in PdfGraph.References(queue.Dequeue()))
            {
                if (reached.Add(reference.Number)) queue.Enqueue(document.Get(reference.Number));
            }
        }
        return document.ObjectNumbers.Count(n => !reached.Contains(n) && document.Get(n) is not null);
    }
}
