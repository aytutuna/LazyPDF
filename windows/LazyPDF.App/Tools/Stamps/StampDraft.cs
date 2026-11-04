using LazyPDF.App.Services;
using LazyPDF.Core;

namespace LazyPDF.App.Tools.Stamps;

/// <summary>What the form describes: one spec of Core's, and the picture file it names, if any.</summary>
public sealed record StampDraft(WatermarkSpec? Watermark = null, BackgroundSpec? Background = null, HeaderFooterSpec? HeaderFooter = null, byte[]? Picture = null)
{
    public StampKind Kind => Watermark is not null ? StampKind.Watermark
        : Background is not null ? StampKind.Background
        : HeaderFooter?.Bates is not null ? StampKind.Bates
        : StampKind.HeaderFooter;

    public string AddText => Watermark is not null ? Loc.T("Add watermark")
        : Background is not null ? Loc.T("Add background")
        : HeaderFooter?.Bates is not null ? Loc.T("Add Bates numbers")
        : Loc.T("Add header and footer");

    /// <summary>What is missing before Core can draw it; null when nothing is.</summary>
    public string? Problem
    {
        get
        {
            if (Watermark is { } mark) return string.IsNullOrWhiteSpace(mark.Text) && Picture is null ? StampsText.NeedsContent : null;
            if (Background is { } back) return back.Color is null && Picture is null ? StampsText.NeedsContent : null;
            var spec = HeaderFooter!;
            if (spec.Bates is not null) return null;
            string[] slots = [spec.Header.Left, spec.Header.Center, spec.Header.Right, spec.Footer.Left, spec.Footer.Center, spec.Footer.Right];
            return slots.All(string.IsNullOrEmpty) ? Loc.T("Type the text for at least one place.") : null;
        }
    }

    /// <summary>Adds the stamp, or replaces run <paramref name="replace"/> with it. The caller commits.</summary>
    /// <exception cref="InvalidOperationException">No font can draw the text.</exception>
    /// <exception cref="InvalidDataException">The picture cannot be read.</exception>
    public StampRun Apply(PdfDocument document, IFontSource fonts, IImageCodec codec, int? replace)
    {
        var stamper = new PdfStamper(document, fonts);
        if (Watermark is { } mark)
        {
            if (Picture is not null) mark = mark with { Text = null, Image = AddPicture(document, codec) };
            return replace is { } id ? stamper.Update(id, mark) : stamper.AddWatermark(mark);
        }
        if (Background is { } back)
        {
            if (Picture is not null) back = back with { Image = AddPicture(document, codec) };
            return replace is { } id ? stamper.Update(id, back) : stamper.AddBackground(back);
        }
        var bands = HeaderFooter!;
        return replace is { } found ? stamper.Update(found, bands) : stamper.AddHeaderFooter(bands);
    }

    private PdfImage AddPicture(PdfDocument document, IImageCodec codec)
    {
        var file = Picture!;
        bool jpeg = file.Length > 2 && file[0] == 0xFF && file[1] == 0xD8;
        if (jpeg && PdfImageWriter.AddJpeg(document, file) is { } direct) return direct;
        var frame = codec.DecodeFile(file)?.FirstOrDefault() ?? throw new InvalidDataException("The picture cannot be read.");
        return PdfImageWriter.AddRgba(document, frame.Width, frame.Height, frame.Rgba);
    }
}
