using System.Globalization;

namespace LazyPDF.Core;

/// <summary>The sentences of the PDF/A checks and conversion. Places are the "where" of an issue.</summary>
public static class PdfAText
{
    public static string Header => Loc.T("File header");
    public static string Trailer => Loc.T("Trailer");
    public static string Xref => Loc.T("Cross-reference");
    public static string Catalog => Loc.T("Catalog");
    public static string Metadata => Loc.T("Metadata");
    public static string Info => Loc.T("Document information");
    public static string Form => Loc.T("Form");
    public static string OutputIntent => Loc.T("Output intent");

    public static string PageName(int page) => Loc.T("Page {0}", page);
    public static string ObjectName(int number) => Loc.T("Object {0}", number);
    public static string AnnotationName(int page, int index) => Loc.T("Page {0}, annotation {1}", page, index);
    public static string FontName(string name) => name.Length == 0 ? Loc.T("Font") : Loc.T("Font {0}", name);

    public static string BytesBeforeHeader => Loc.T("Bytes come before the %PDF header.");
    public static string HeaderMissing => Loc.T("The header line is missing.");
    public static string HeaderVersion(string version) => Loc.T("The header names version {0}; it must be 1.0 to 1.7.", version);
    public static string HeaderVersion4(string version) => Loc.T("The header names version {0}; it must be 2.0.", version);
    public static string HeaderComment => Loc.T("The second line must be a comment of four bytes above 127.");
    public static string NoEof => Loc.T("The file does not end with %%EOF.");
    public static string DataAfterEof => Loc.T("Data follows the last %%EOF.");
    public static string NoId => Loc.T("The trailer has no /ID of two strings.");
    public static string Encrypted => Loc.T("The file is encrypted.");
    public static string XrefDamaged => Loc.T("The cross-reference data is damaged and had to be rebuilt.");
    public static string XrefStream => Loc.T("The file uses a cross-reference stream, which PDF 1.4 does not have.");
    public static string ObjectStreams => Loc.T("The file uses object streams, which PDF 1.4 does not have.");
    public static string StreamKeyword => Loc.T("The stream keyword must be followed by CRLF or LF.");
    public static string StreamLength => Loc.T("The /Length of a stream does not match its data.");
    public static string StreamKey(string key) => Loc.T("A stream has the key /{0}, which is not allowed.", key);
    public static string Lzw => Loc.T("A stream uses the LZW filter.");
    public static string CryptFilter => Loc.T("A stream uses the Crypt filter.");
    public static string UnknownFilter(string name) => Loc.T("A stream uses the filter {0}, which the standard does not list.", name);
    public static string HexString => Loc.T("A hexadecimal string has an odd number of digits or a character that is not a hex digit.");

    public static string StringTooLong(int length) => Loc.T("A string is {0} bytes long, past the limit.", length);
    public static string NameTooLong => Loc.T("A name is longer than 127 bytes.");
    public static string IntegerTooBig(string text) => Loc.T("The integer {0} is outside the 32-bit range.", text);
    public static string ArrayTooLong(int count) => Loc.T("An array has {0} elements; the limit is 8191.", count);
    public static string DictionaryTooBig(int count) => Loc.T("A dictionary has {0} entries; the limit is 4095.", count);
    public static string RealTooBig(string text) => Loc.T("The real number {0} is beyond 32767.", text);
    public static string TooMuchContent => Loc.T("The page content is too large to check in full.");
    public static string GraphicsNesting => Loc.T("Graphics states are nested more than 28 deep.");
    public static string TooManyColorants(int limit) => Loc.T("A DeviceN space has more than {0} color channels.", limit);

    public static string EmbeddedFile => Loc.T("The file embeds another file, which this level does not allow.");
    public static string EmbeddedNotPdfA => Loc.T("An embedded file is not a PDF/A file.");
    public static string NoRelationship => Loc.T("A file specification has no /AFRelationship.");
    public static string NoMimeType => Loc.T("An embedded file stream has no /Subtype giving its MIME type.");

    public static string DeviceColor(string family) => Loc.T("{0} is used and the file has no output intent or default space for it.", family);
    public static string UnknownOperator(string name) => Loc.T("The content uses the operator {0}, which the standard does not define.", name);
    public static string RenderingIntent(string name) => Loc.T("The rendering intent {0} is not one of the four standard ones.", name);
    public static string TransparencyGroup => Loc.T("A page or form has a transparency group.");
    public static string PostScriptObject => Loc.T("A PostScript XObject is used.");
    public static string ReferenceXObject => Loc.T("A form XObject has a /Ref entry.");
    public static string TransferFunction => Loc.T("A graphics state sets a transfer function.");
    public static string Halftone => Loc.T("A graphics state sets a halftone.");
    public static string BlendMode(string? mode) => Loc.T("The blend mode {0} needs transparency.", mode);
    public static string UnknownBlendMode(string mode) => Loc.T("The blend mode {0} is not one of the standard ones.", mode);
    public static string Opacity => Loc.T("A constant opacity below 1 needs transparency.");
    public static string SoftMask => Loc.T("A soft mask needs transparency.");
    public static string ImageTransparency => Loc.T("An image has a soft mask or alpha data.");
    public static string Opi => Loc.T("An object has an /OPI entry.");
    public static string Interpolate => Loc.T("An image sets /Interpolate to true.");
    public static string Alternates => Loc.T("An image has /Alternates.");
    public static string Jpx => Loc.T("An image uses JPEG 2000, which PDF 1.4 does not have.");
    public static string ContentUnreadable => Loc.T("A content stream could not be read.");
    public static string SeparationDiffers(string name) => Loc.T("Separation {0} is defined more than once with different alternates.", name);

    public static string ProfileComponents => Loc.T("An ICC profile stream has no usable /N.");
    public static string ProfileUnreadable => Loc.T("An ICC profile could not be read.");
    public static string ProfileClass(string kind) => Loc.T("An ICC profile of class {0} is not allowed.", kind);
    public static string ProfileSpace => Loc.T("An ICC profile does not match the color count in /N.");
    public static string ProfileVersion(int version) => Loc.T("An ICC profile is version {0}, newer than this level allows.", version);

    public static string WidthDiffers(int code, double declared, double actual) =>
        Loc.T("The width of {0} is {1} but the font program says {2}.", code, declared.ToString("0.##", CultureInfo.InvariantCulture), actual.ToString("0.##", CultureInfo.InvariantCulture));
    public static string FontNotEmbedded => Loc.T("The font is not embedded.");
    public static string FontProgramUnreadable => Loc.T("The embedded font program could not be read.");
    public static string FontFileSubtype => Loc.T("The font file has no valid /Subtype.");
    public static string NoWidths => Loc.T("The font has no /Widths or /FirstChar.");
    public static string CMapNotKnown => Loc.T("The font names a CMap that is neither predefined nor embedded.");
    public static string NoSystemInfo => Loc.T("The CIDFont has no /CIDSystemInfo.");
    public static string NoCidToGid => Loc.T("A TrueType CIDFont has no /CIDToGIDMap.");
    public static string CidSetIncomplete => Loc.T("The /CIDSet does not list every glyph shown or held in the font program.");
    public static string CharSetIncomplete => Loc.T("The /CharSet does not list every glyph shown or held in the font program.");
    public static string CidSetMissing => Loc.T("A subset CIDFont has no /CIDSet.");
    public static string CharSetMissing => Loc.T("A subset Type 1 font has no /CharSet.");
    public static string SymbolicEncoding => Loc.T("A symbolic TrueType font has an /Encoding.");
    public static string SymbolicCmap => Loc.T("A symbolic TrueType font has no (3,0) or (1,0) cmap.");
    public static string TrueTypeEncoding => Loc.T("A TrueType font must use WinAnsiEncoding or MacRomanEncoding.");
    public static string TrueTypeDifferences => Loc.T("The /Differences of a TrueType font need names from the Adobe Glyph List and a (3,1) cmap.");
    public static string NoUnicode => Loc.T("The font has no /ToUnicode and its text cannot be traced another way.");

    public static string AnnotationType(string? subtype) => subtype is null ? Loc.T("An annotation has no subtype.") : Loc.T("The annotation type {0} is not allowed.", subtype);
    public static string NoPrintFlag => Loc.T("The Print flag of the annotation is not set.");
    public static string HiddenAnnotation => Loc.T("The annotation is hidden, invisible or not shown on screen.");
    public static string NoAppearance => Loc.T("The annotation has no normal appearance stream.");
    public static string AppearanceKeys => Loc.T("The appearance dictionary has keys other than /N.");
    public static string ButtonAppearance => Loc.T("The /N of a button widget must be a dictionary of states.");
    public static string AppearanceNotStream => Loc.T("The /N of an annotation must be a stream.");
    public static string FieldTriggers => Loc.T("A field or widget has an /AA entry.");
    public static string CatalogTriggers => Loc.T("The catalog has an /AA entry.");
    public static string PageTriggers => Loc.T("A page has an /AA entry.");
    public static string WidgetAction => Loc.T("A widget has an /A entry.");
    public static string TriggerKey(string key) => Loc.T("An additional-actions dictionary has the key /{0}, which is not allowed.", key);
    public static string JavaScript => Loc.T("JavaScript is used.");
    public static string ForbiddenAction(string type) => Loc.T("A {0} action is used.", type);
    public static string NamedAction(string? name) => Loc.T("The named action {0} is not allowed.", name);
    public static string Outlines => Loc.T("Outlines");
    public static string AnnotationColor => Loc.T("An annotation has /C or /IC and the output intent is not an RGB profile.");
    public static string NeedsRendering => Loc.T("The catalog has /NeedsRendering.");
    public static string NeedAppearances => Loc.T("The form sets /NeedAppearances to true.");
    public static string Xfa => Loc.T("The form has XFA data.");

    public static string MetadataFilter => Loc.T("The metadata stream has a /Filter.");
    public static string NoMetadata => Loc.T("The catalog has no /Metadata stream.");
    public static string XmpTooBig => Loc.T("The XMP packet is too large to read.");
    public static string XmpNoRdf => Loc.T("The XMP packet has no rdf:RDF element.");
    public static string XmpNotWellFormed => Loc.T("The XMP packet is not well-formed XML.");
    public static string NoIdentification => Loc.T("The XMP has no PDF/A identification (pdfaid:part).");
    public static string WrongPart(string found, int wanted) => Loc.T("The XMP says part {0}; part {1} is checked.", found, wanted);
    public static string NoRevision => Loc.T("The XMP has no pdfaid:rev of 2020.");
    public static string WrongConformance(string? found, string wanted) => Loc.T("The XMP says conformance {0}; {1} is needed.", found ?? Loc.T("none|no conformance"), wanted);
    public static string NoExtensionSchema(string ns) => Loc.T("The XMP uses properties of {0} with no extension schema.", ns);
    public static string InfoKey(string key) => Loc.T("The information dictionary has /{0}, which this level does not allow.", key);
    public static string InfoDiffers(string key, string property) => Loc.T("/{0} does not match {1} in the XMP.", key, property);
    public static string NoConditionIdentifier => Loc.T("An output intent has no /OutputConditionIdentifier.");
    public static string NoProfile => Loc.T("A PDF/A output intent has no /DestOutputProfile.");
    public static string ProfilesDiffer => Loc.T("The output intents use different profiles.");
    public static string OptionalContent => Loc.T("The catalog has /OCProperties.");
    public static string NoDefaultConfig => Loc.T("The optional content has no default configuration.");
    public static string ConfigName => Loc.T("An optional content configuration has no /Name.");
    public static string ConfigNameTwice => Loc.T("Two optional content configurations have the same name.");
    public static string AutoState => Loc.T("An optional content configuration has /AS.");
    public static string OrderIncomplete => Loc.T("The /Order of a configuration leaves out some groups.");

    public static string NoMarkInfo => Loc.T("The catalog has no /MarkInfo with /Marked true.");
    public static string NoStructTree => Loc.T("The file has no structure tree.");
    public static string EmptyStructTree => Loc.T("The structure tree has no elements.");
    public static string StructTreeTooBig => Loc.T("The structure tree is too large to check in full.");
    public static string ContentOutsideTree => Loc.T("Content is neither in the structure tree nor marked as an artifact.");
    public static string NoStructParents => Loc.T("A page with tagged content has no /StructParents.");
    public static string ParentTreeMismatch => Loc.T("The parent tree does not lead the content of this page back to the structure elements that hold it.");
    public static string NonStandardType(string type) => Loc.T("The structure type {0} is not a standard type and the role map does not lead to one.", type);
    public static string NoAlternateText(string type) => Loc.T("A {0} element has neither /Alt nor /ActualText.", type);
    public static string NoLanguage => Loc.T("No natural language is set in the catalog or on the top structure elements.");
    public static string StructureElement(int number) => Loc.T("Structure element {0}", number);
    public static string SetLanguageToTag => Loc.T("Set the document language first and Lazy PDF can tag the file itself.");
    public static string TagFirst(PdfALevel level, IEnumerable<string> problems, string? hint = null) =>
        string.Join(' ', [Loc.T("{0} needs a tagged file, and this one is not tagged well enough: {1} Tag the file and fix these first, then convert again.", level.Name(), string.Join(' ', problems)), .. hint is null ? [] : new[] { hint }]);
    public static string Tagged(int pages) => Loc.T("The file was tagged automatically ({0} pages). Check the reading order and the descriptions.", pages);
    public static string Marked => Loc.T("The file was marked as tagged.");

    public const string Producer = "Lazy PDF";
    public static string NeedsPassword => Loc.T("The file needs a password.");
    public static string Unreadable => Loc.T("The file could not be read.");
    public static string NoRights => Loc.T("The file's permissions do not allow changing it, so it cannot be converted.");
    public static string DynamicXfa => Loc.T("The file is a dynamic XFA form, which has no pages of its own to keep.");
    public static string Transparency(IEnumerable<string> reasons) =>
        Loc.T("PDF/A-1 does not allow transparency and it cannot be flattened here. {0} Convert to PDF/A-2 or later instead.", string.Join(' ', reasons));
    public static string CouldNotRewrite(string detail) => Loc.T("The file could not be rewritten: {0}", detail);

    public static string EncryptionRemoved => Loc.T("The encryption was removed.");
    public static string SignaturesBroken => Loc.T("The file was signed; its signatures no longer verify.");
    public static string ActionsRemoved(int count) => Loc.T("{0} actions or scripts were removed.", count);
    public static string AnnotationsRemoved(int count) => Loc.T("{0} annotations of a kind this level does not allow were removed.", count);
    public static string FlagsSet(int count) => Loc.T("The print and visibility flags of {0} annotations were corrected.", count);
    public static string AppearancesDrawn(int count) => Loc.T("Appearances were drawn for {0} annotations.", count);
    public static string FieldsDrawn(int count) => Loc.T("Appearances were drawn for {0} form fields.", count);
    public static string IntegersClamped(int count) => Loc.T("{0} integers beyond 32 bits were cut to the limit.", count);
    public static string GroupsRemoved(int count) => Loc.T("{0} transparency groups were removed; nothing on the pages needed them.", count);
    public static string XfaRemoved => Loc.T("The XFA data was removed; the form keeps its normal fields.");
    public static string StreamsRecoded(int count) => Loc.T("{0} streams were recompressed without LZW.", count);
    public static string LayersRemoved => Loc.T("The layers were removed; hidden layers now show.");
    public static string AttachmentsRemoved(int count) => Loc.T("{0} embedded files were removed.", count);
    public static string AttachmentsDescribed(int count) => Loc.T("{0} embedded files were given a relationship and a type.", count);
    public static string IntentAdded => Loc.T("An sRGB output intent was added.");
    public static string NotDeclared(PdfALevel level) => Loc.T("The XMP metadata does not name {0}, because rules are still broken.", level.Name());

    public static string MetadataWritten(PdfALevel level) => Loc.T("The XMP metadata now identifies the file as {0}.", level.Name());
    public static string FontsEmbedded(int count) => Loc.T("{0} fonts were embedded.", count);
    public static string FontsCorrected(int count) => Loc.T("{0} fonts were corrected.", count);
}
