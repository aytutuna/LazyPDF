namespace LazyPDF.Core;

/// <summary>
/// An area to remove from one page, in user space. <paramref name="Fill"/> is the colour it is
/// covered with (gray, RGB or CMYK, 0 to 1; black when null) and <paramref name="OverlayText"/> the text
/// drawn on it, such as a reason code.
/// </summary>
public sealed record RedactionMark(int Page, IReadOnlyList<TextQuad> Quads, double[]? Fill = null, string? OverlayText = null)
{
    public static RedactionMark FromRect(int page, PdfRect rect, double[]? fill = null, string? overlayText = null) =>
        new(page, [new TextQuad(rect.Left, rect.Bottom, rect.Right, rect.Bottom, rect.Right, rect.Top, rect.Left, rect.Top)], fill, overlayText);

    public static RedactionMark FromMatch(SearchMatch match, double[]? fill = null, string? overlayText = null) =>
        new(match.Page, match.Quads, fill, overlayText);
}

/// <summary>What <see cref="PdfRedactor.Apply(IEnumerable{RedactionMark}, RedactionOptions?)"/> does besides removing.</summary>
public sealed record RedactionOptions
{
    /// <summary>Colour for marks that give none; black when null.</summary>
    public double[]? Fill { get; init; }

    /// <summary>Text drawn on marks that give none.</summary>
    public string? OverlayText { get; init; }

    /// <summary>Repeat the overlay text across the mark instead of drawing it once.</summary>
    public bool RepeatOverlay { get; init; }

    public string FontFamily { get; init; } = "Helvetica";

    /// <summary>The report lists the removed text. Off by default, so a report can be kept or shared.</summary>
    public bool IncludeText { get; init; }

    /// <summary>Replace the removed text where /Info, the XMP packet and bookmark titles hold it. They are reported either way.</summary>
    public bool ChangeMetadata { get; init; }

    /// <summary>
    /// Draws the pages that cannot be redacted as text (see <see cref="PdfRedactor.Apply(IEnumerable{RedactionMark}, RedactionOptions?)"/>).
    /// It draws the document handed to the redactor. Without one, such a page makes the call throw.
    /// </summary>
    public IPageRenderer? Renderer { get; init; }

    /// <summary>Every page with a mark becomes a picture, as a page that is not understood does; without a renderer the call throws.</summary>
    public bool FlattenMarkedPages { get; init; }

    /// <summary>The resolution a page is drawn at when it becomes a picture, at most 1200.</summary>
    public double FlattenDpi { get; init; } = 200;

    /// <summary>Write the output with the input's encryption. A file opened with a password needs it again to open.</summary>
    public bool KeepEncryption { get; init; } = true;
}

/// <summary>The output of an application: always a full rewrite with no earlier revision in it.</summary>
public sealed record RedactionResult(byte[] Bytes, RedactionReport Report, RedactionVerification Verification);

/// <summary>What the check of the output found. Problems say where, never what.</summary>
public sealed record RedactionVerification(IReadOnlyList<string> Problems)
{
    public bool IsClean => Problems.Count == 0;
}

/// <summary>A place outside the page content that held removed text.</summary>
public sealed record RedactionFinding(string Where, bool Changed);

/// <summary>What was taken out of one page. <paramref name="Values"/> counts the annotations and fields whose text was rewritten.</summary>
public sealed record PageRedaction(int Page, int Glyphs, int Images, int Paths, int Annotations, int Fields, int Values = 0)
{
    public bool IsEmpty => Glyphs + Images + Paths + Annotations + Fields + Values == 0;
}

public sealed record RedactionReport(IReadOnlyList<PageRedaction> Pages, IReadOnlyList<RedactionFinding> Findings,
    int SignaturesRemoved, IReadOnlyList<string> Text)
{
    public int Glyphs => Pages.Sum(p => p.Glyphs);
    public int Images => Pages.Sum(p => p.Images);
    public int Paths => Pages.Sum(p => p.Paths);
    public int Annotations => Pages.Sum(p => p.Annotations);
    public int Fields => Pages.Sum(p => p.Fields);

    /// <summary>The pages (from 0) that were turned into pictures; their text is no longer selectable.</summary>
    public IReadOnlyList<int> Flattened { get; init; } = [];

    /// <summary>The report in plain words, one line a page.</summary>
    public override string ToString()
    {
        var lines = Pages.Where(p => !p.IsEmpty).Select(RedactionText.Line).ToList();
        if (lines.Count == 0 && Flattened.Count == 0) lines.Add(RedactionText.NothingFound);
        lines.AddRange(Flattened.Select(RedactionText.Flattened));
        lines.AddRange(Findings.Select(f => f.Changed ? RedactionText.MetadataChanged(f.Where) : RedactionText.MetadataHolds(f.Where)));
        if (SignaturesRemoved > 0) lines.Add(RedactionText.SignaturesGone(SignaturesRemoved));
        lines.AddRange(Text.Select(RedactionText.Removed));
        return string.Join('\n', lines);
    }
}
