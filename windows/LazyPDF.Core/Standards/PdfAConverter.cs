namespace LazyPDF.Core;

/// <summary>
/// The outcome of a conversion. <see cref="Bytes"/> is the new file, null when the conversion was
/// refused and <see cref="Refusal"/> says why. <see cref="Remaining"/> is what the validator still finds in the
/// result, empty when it is clean; <see cref="Changes"/> says in sentences what was altered.
/// </summary>
public sealed record PdfAConversion(byte[]? Bytes, string? Refusal, IReadOnlyList<PdfAIssue> Remaining, IReadOnlyList<string> Changes)
{
    public bool IsClean => Bytes is not null && Remaining.Count == 0;
}

/// <summary>
/// Takes a PDF to a PDF/A level by rewriting it. It embeds or replaces fonts from the font source, corrects widths,
/// drops encryption, actions, JavaScript and forbidden annotations, draws missing appearances, rewrites LZW, adds the
/// sRGB output intent and writes the XMP identification with /Info in step, but only when nothing remains broken: a file
/// that still fails gets the same metadata without the pdfaid claim. It refuses what it cannot do honestly
/// (transparency for part 1, an encrypted file whose permissions forbid changes, a dynamic XFA form); what it leaves
/// broken it reports in <see cref="PdfAConversion.Remaining"/>.
/// </summary>
public sealed class PdfAConverter(IFontSource? fonts = null)
{
    /// <summary>Converts <paramref name="pdf"/>; <paramref name="date"/> is the time of conversion, for ModDate and the metadata date.</summary>
    public PdfAConversion Convert(byte[] pdf, PdfALevel level, DateTimeOffset date, string? password = null) =>
        new PdfAConversionRun(fonts, level, date).Run(pdf, password);
}

internal sealed partial class PdfAConversionRun(IFontSource? fonts, PdfALevel level, DateTimeOffset date)
{
    private readonly List<string> _changes = [];
    private readonly List<PdfAIssue> _left = [];
    private PdfDocument _doc = null!;
    private DocumentMetadata? _meta;

    private int Part => level.Part();

    public PdfAConversion Run(byte[] pdf, string? password)
    {
        try
        {
            _doc = PdfDocument.Open(pdf, password);
        }
        catch (PdfReadException e)
        {
            return Refused(e.Problem == PdfReadProblem.PasswordRequired ? PdfAText.NeedsPassword : PdfAText.Unreadable);
        }
        using (_doc)
        {
            if (_doc.Security is { } security && !security.OpenedAsOwner && !security.Permissions.HasFlag(PdfPermissions.Modify)) return Refused(PdfAText.NoRights);
            if (PdfForm.Read(_doc).Xfa == XfaKind.Dynamic) return Refused(PdfAText.DynamicXfa);
            var before = new PdfAChecker(_doc, level);
            before.Run();
            var needed = before.Report().Issues.Where(i => i.Clause == "6.4" && i.Message != PdfAText.TransparencyGroup).Select(i => i.Message).Distinct().ToList();
            if (Part == 1 && needed.Count > 0) return Refused(PdfAText.Transparency(needed));
            try
            {
                Apply(before);
                byte[] bytes = _doc.SaveRewrite();
                SetHeaderVersion(bytes);
                using var written = PdfDocument.Open(bytes);
                var left = PdfAValidator.Validate(written, level).Issues.Union(_left).ToList();
                if (left.Count > 0)
                {
                    PutPacket(declare: false);
                    _changes.Remove(PdfAText.MetadataWritten(level));
                    Changed(PdfAText.NotDeclared(level));
                    bytes = _doc.SaveRewrite();
                    SetHeaderVersion(bytes);
                    // What the delivered file fails is what a validator will say of it, which includes the missing identification.
                    using var delivered = PdfDocument.Open(bytes);
                    left = PdfAValidator.Validate(delivered, level).Issues.Union(_left).ToList();
                }
                return new PdfAConversion(bytes, null, left, _changes);
            }
            catch (PdfReadException e)
            {
                return Refused(PdfAText.CouldNotRewrite(e.Message));
            }
        }
    }

    private PdfAConversion Refused(string reason) => new(null, reason, [], _changes);

    private void Apply(PdfAChecker before)
    {
        if (_doc.IsEncrypted) Changed(PdfAText.EncryptionRemoved);
        if (_doc.IsSigned) Changed(PdfAText.SignaturesBroken);
        var parts = Collect();
        RemoveActions(parts);
        ClampIntegers(parts);
        if (Part == 1) RemoveGroups(parts);
        FixAnnotations();
        FixForm();
        FixStreams(parts);
        FixOptionalContent();
        FixEmbeddedFiles(parts);
        FixFonts(before);
        SetOutputIntent();
        SetMetadata();
        _doc.Catalog.Remove("Version");
    }

    private void Changed(string text) => _changes.Add(text);

    // The header is written by the saver from the document's version; the same number of bytes, so the offsets hold.
    private void SetHeaderVersion(byte[] bytes)
    {
        string version = Part switch { 1 => "1.4", 4 => "2.0", _ => "1.7" };
        for (int i = 0; i < 3; i++) bytes[5 + i] = (byte)version[i];
    }
}
