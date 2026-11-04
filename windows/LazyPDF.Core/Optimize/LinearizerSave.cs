namespace LazyPDF.Core;

public sealed partial class PdfDocument
{
    /// <summary>
    /// A new file of the objects reachable from the trailer, laid out for page-at-a-time viewing
    /// (ISO 32000-1 Annex F): the first page's objects up front with their own cross-reference
    /// section, the hint tables that locate every other page, then the rest. Numbered afresh, no
    /// history, signatures do not survive. <paramref name="options"/> is read as by
    /// <see cref="SaveRewrite"/> for its handler and id; object streams are never used, since the
    /// cross-reference sections of a linearized file are tables. A change to the result by
    /// <see cref="SaveIncremental"/> leaves a valid file that is no longer linearized.
    /// </summary>
    public byte[] SaveLinearized(PdfSaveOptions? options = null)
    {
        options ??= new PdfSaveOptions();
        RequireEncryptionRights(options.Security);
        return new Linearizer(this, options).Run();
    }
}
