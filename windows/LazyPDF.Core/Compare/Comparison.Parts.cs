namespace LazyPDF.Core;

internal sealed partial class Comparison
{
    private const double SizeTolerance = 0.1;
    private const double PlaceTolerance = 1;
    private const double MinOverlap = 0.6;

    /// <summary>Words that are equal on both sides but are set in another font, size or colour; neighbours with the same difference are one change.</summary>
    private void CompareFormats(PairWork work, PageData oldData, PageData newData, List<SequenceDiff.Hunk> hunks)
    {
        string? runDetail = null;
        int runOld = 0, runNew = 0, runCount = 0;
        void Flush()
        {
            if (runCount > 0)
            {
                work.Others.Add(new CompareChange(ChangeKind.Changed, ChangeArea.Format, work.Pair.OldIndex, work.Pair.NewIndex,
                    oldData.Words(runOld, runCount), newData.Words(runNew, runCount), oldData.Quads(runOld, runCount), newData.Quads(runNew, runCount), runDetail));
            }
            runCount = 0;
        }
        void Equal(int i, int j)
        {
            string? detail = FormatDifference(oldData.FormatChar(i), newData.FormatChar(j));
            if (detail is null || detail != runDetail || runOld + runCount != i || runNew + runCount != j) Flush();
            if (detail is null) return;
            if (runCount == 0) (runDetail, runOld, runNew) = (detail, i, j);
            runCount++;
        }

        int a = 0, b = 0;
        foreach (var hunk in hunks)
        {
            while (a < hunk.OldStart) Equal(a++, b++);
            (a, b) = (hunk.OldStart + hunk.OldCount, hunk.NewStart + hunk.NewCount);
        }
        while (a < oldData.Ids.Length) Equal(a++, b++);
        Flush();
    }

    private static string? FormatDifference(TextChar a, TextChar b)
    {
        var parts = new List<string>();
        string fontA = a.Font?.Name ?? "", fontB = b.Font?.Name ?? "";
        if (!string.Equals(fontA, fontB, StringComparison.OrdinalIgnoreCase)) parts.Add(CompareText.FontChange(fontA, fontB));
        if (Math.Abs(a.Size - b.Size) > SizeTolerance) parts.Add(CompareText.SizeChange(a.Size, b.Size));
        if (a.Color != b.Color) parts.Add(CompareText.ColorChange(a.Color, b.Color));
        return parts.Count == 0 ? null : string.Join("; ", parts);
    }

    private void CompareImages(PairWork work, PdfPage oldPage, PdfPage newPage)
    {
        var oldImages = _oldReader.Images(oldPage);
        var newImages = _newReader.Images(newPage);
        if (oldImages.Count == 0 && newImages.Count == 0) return;
        var pair = work.Pair;
        var usedOld = new bool[oldImages.Count];
        var usedNew = new bool[newImages.Count];

        void Report(ChangeKind kind, PageImage? old, PageImage? updated, string? detail)
        {
            work.Others.Add(new CompareChange(kind, ChangeArea.Image, pair.OldIndex, pair.NewIndex, "", "",
                old is null ? [] : [BoxQuad(old.Bounds)], updated is null ? [] : [BoxQuad(updated.Bounds)], detail));
        }

        for (int j = 0; j < newImages.Count; j++)
        {
            int i = Find(oldImages, usedOld, newImages[j], sameHash: true, samePlace: true);
            if (i < 0) continue;
            usedOld[i] = usedNew[j] = true;
        }
        for (int j = 0; j < newImages.Count; j++)
        {
            if (usedNew[j]) continue;
            int i = Find(oldImages, usedOld, newImages[j], sameHash: true, samePlace: false);
            if (i < 0) continue;
            usedOld[i] = usedNew[j] = true;
            Report(ChangeKind.Changed, oldImages[i], newImages[j], CompareText.ImageMoved);
        }
        for (int j = 0; j < newImages.Count; j++)
        {
            if (usedNew[j]) continue;
            int i = Find(oldImages, usedOld, newImages[j], sameHash: false, samePlace: true);
            if (i < 0) continue;
            usedOld[i] = usedNew[j] = true;
            Report(ChangeKind.Changed, oldImages[i], newImages[j], CompareText.ImageReplaced);
        }
        for (int j = 0; j < newImages.Count; j++)
        {
            if (!usedNew[j]) Report(ChangeKind.Added, null, newImages[j], null);
        }
        for (int i = 0; i < oldImages.Count; i++)
        {
            if (!usedOld[i]) Report(ChangeKind.Removed, oldImages[i], null, null);
        }
    }

    /// <summary>The unused old picture with the same hash (or, without <paramref name="sameHash"/>, a different one) at the same place (or the nearest one when places differ).</summary>
    private static int Find(List<PageImage> candidates, bool[] used, PageImage image, bool sameHash, bool samePlace)
    {
        int best = -1;
        double bestDistance = double.MaxValue;
        for (int i = 0; i < candidates.Count; i++)
        {
            if (used[i] || (candidates[i].Hash == image.Hash) != sameHash) continue;
            var a = candidates[i].Bounds;
            var b = image.Bounds;
            bool near = Math.Abs(a.Left - b.Left) <= PlaceTolerance && Math.Abs(a.Right - b.Right) <= PlaceTolerance
                && Math.Abs(a.Bottom - b.Bottom) <= PlaceTolerance && Math.Abs(a.Top - b.Top) <= PlaceTolerance;
            if (samePlace && sameHash && !near) continue;
            if (samePlace && !sameHash && Overlap(a, b) < MinOverlap) continue;
            double distance = Math.Abs(a.Left + a.Right - b.Left - b.Right) + Math.Abs(a.Bottom + a.Top - b.Bottom - b.Top);
            if (distance < bestDistance) (best, bestDistance) = (i, distance);
        }
        return best;
    }

    private static double Overlap(PdfRect a, PdfRect b)
    {
        var both = a.Intersect(b);
        double area = both.IsEmpty ? 0 : both.Width * both.Height;
        double union = a.Width * a.Height + b.Width * b.Height - area;
        return union <= 0 ? 0 : area / union;
    }

    private void CompareAnnotations(PairWork work, PdfPage oldPage, PdfPage newPage)
    {
        var oldNotes = Notes(_before, oldPage);
        var newNotes = Notes(_after, newPage);
        if (oldNotes.Count == 0 && newNotes.Count == 0) return;
        var pair = work.Pair;
        var usedOld = new bool[oldNotes.Count];
        var matched = new List<(int Old, int New)>();
        for (int j = 0; j < newNotes.Count; j++)
        {
            if (newNotes[j].Name is not { Length: > 0 } name) continue;
            int i = Enumerable.Range(0, oldNotes.Count).FirstOrDefault(k => !usedOld[k] && oldNotes[k].Name == name, -1);
            if (i < 0) continue;
            usedOld[i] = true;
            matched.Add((i, j));
        }
        var done = matched.Select(m => m.New).ToHashSet();
        for (int j = 0; j < newNotes.Count; j++)
        {
            if (done.Contains(j)) continue;
            int best = -1;
            double bestOverlap = MinOverlap - 1e-9;
            for (int i = 0; i < oldNotes.Count; i++)
            {
                if (usedOld[i] || oldNotes[i].Subtype != newNotes[j].Subtype) continue;
                double overlap = Overlap(oldNotes[i].Rect, newNotes[j].Rect);
                if (overlap > bestOverlap) (best, bestOverlap) = (i, overlap);
            }
            if (best < 0) continue;
            usedOld[best] = true;
            matched.Add((best, j));
            done.Add(j);
        }

        foreach (var (i, j) in matched.OrderBy(m => m.New))
        {
            var a = oldNotes[i];
            var b = newNotes[j];
            var parts = new List<string>();
            if ((a.Contents ?? "") != (b.Contents ?? "")) parts.Add(CompareText.AnnotationText);
            if (!SameRect(a.Rect, b.Rect)) parts.Add(CompareText.AnnotationPosition);
            if (!SameColor(a.Color, b.Color)) parts.Add(CompareText.AnnotationColor);
            if (parts.Count == 0) continue;
            work.Others.Add(new CompareChange(ChangeKind.Changed, ChangeArea.Annotation, pair.OldIndex, pair.NewIndex, a.Contents ?? "", b.Contents ?? "",
                NoteQuads(a), NoteQuads(b), $"{b.Subtype}: {string.Join(", ", parts)}"));
        }
        for (int j = 0; j < newNotes.Count; j++)
        {
            if (done.Contains(j)) continue;
            var b = newNotes[j];
            work.Others.Add(new CompareChange(ChangeKind.Added, ChangeArea.Annotation, pair.OldIndex, pair.NewIndex, "", b.Contents ?? "", [], NoteQuads(b), b.Subtype));
        }
        for (int i = 0; i < oldNotes.Count; i++)
        {
            if (usedOld[i]) continue;
            var a = oldNotes[i];
            work.Others.Add(new CompareChange(ChangeKind.Removed, ChangeArea.Annotation, pair.OldIndex, pair.NewIndex, a.Contents ?? "", "", NoteQuads(a), [], a.Subtype));
        }
    }

    /// <summary>Popups belong to their note and widgets are the form's; both are compared elsewhere or not at all.</summary>
    private static List<PdfAnnotation> Notes(PdfDocument document, PdfPage page) =>
        [.. PdfAnnotations.Read(document, page).Where(a => a.Type is not (AnnotationType.Popup or AnnotationType.Widget))];

    private static List<TextQuad> NoteQuads(PdfAnnotation note) => [BoxQuad(note.Rect)];

    private static bool SameRect(PdfRect a, PdfRect b) =>
        Math.Abs(a.Left - b.Left) <= PlaceTolerance && Math.Abs(a.Right - b.Right) <= PlaceTolerance
        && Math.Abs(a.Bottom - b.Bottom) <= PlaceTolerance && Math.Abs(a.Top - b.Top) <= PlaceTolerance;

    private static bool SameColor(IReadOnlyList<double>? a, IReadOnlyList<double>? b)
    {
        if (a is null || b is null) return a is null && b is null;
        return a.Count == b.Count && a.Zip(b).All(p => Math.Abs(p.First - p.Second) < 0.01);
    }
}
