using System.Globalization;

namespace LazyPDF.Core;

/// <summary>The sentences of the PDF/A checks and conversion. Places are the "where" of an issue.</summary>
public static class PdfAText
{
    private static string F(FormattableString text) => text.ToString(CultureInfo.InvariantCulture);

    public const string Header = "File header";
    public const string Trailer = "Trailer";
    public const string Xref = "Cross-reference";
    public const string Catalog = "Catalog";
    public const string Metadata = "Metadata";
    public const string Info = "Document information";
    public const string Form = "Form";
    public const string OutputIntent = "Output intent";

    public static string PageName(int page) => F($"Page {page}");
    public static string ObjectName(int number) => F($"Object {number}");
    public static string AnnotationName(int page, int index) => F($"Page {page}, annotation {index}");
    public static string FontName(string name) => name.Length == 0 ? "Font" : $"Font {name}";

    public const string BytesBeforeHeader = "Bytes come before the %PDF header.";
    public const string HeaderMissing = "The header line is missing.";
    public static string HeaderVersion(string version) => $"The header names version {version}; it must be 1.0 to 1.7.";
    public static string HeaderVersion4(string version) => $"The header names version {version}; it must be 2.0.";
    public const string HeaderComment = "The second line must be a comment of four bytes above 127.";
    public const string NoEof = "The file does not end with %%EOF.";
    public const string DataAfterEof = "Data follows the last %%EOF.";
    public const string NoId = "The trailer has no /ID of two strings.";
    public const string Encrypted = "The file is encrypted.";
    public const string XrefDamaged = "The cross-reference data is damaged and had to be rebuilt.";
    public const string XrefStream = "The file uses a cross-reference stream, which PDF 1.4 does not have.";
    public const string ObjectStreams = "The file uses object streams, which PDF 1.4 does not have.";
    public const string StreamKeyword = "The stream keyword must be followed by CRLF or LF.";
    public const string StreamLength = "The /Length of a stream does not match its data.";
    public static string StreamKey(string key) => $"A stream has the key /{key}, which is not allowed.";
    public const string Lzw = "A stream uses the LZW filter.";
    public const string CryptFilter = "A stream uses the Crypt filter.";

    public static string StringTooLong(int length) => F($"A string is {length} bytes long, past the limit.");
    public const string NameTooLong = "A name is longer than 127 bytes.";
    public static string IntegerTooBig(string text) => $"The integer {text} is outside the 32-bit range.";
    public static string ArrayTooLong(int count) => F($"An array has {count} elements; the limit is 8191.");
    public static string DictionaryTooBig(int count) => F($"A dictionary has {count} entries; the limit is 4095.");
    public const string GraphicsNesting = "Graphics states are nested more than 28 deep.";
    public const string TooManyColorants = "A DeviceN space has more than 32 colorants.";

    public const string EmbeddedFile = "The file embeds another file, which this level does not allow.";
    public const string EmbeddedNotPdfA = "An embedded file is not a PDF/A file.";
    public const string NoRelationship = "A file specification has no /AFRelationship.";
    public const string NoMimeType = "An embedded file stream has no /Subtype giving its MIME type.";

    public static string DeviceColor(string family) => $"{family} is used and the file has no output intent or default space for it.";
    public static string UnknownOperator(string name) => $"The content uses the operator {name}, which the standard does not define.";
    public static string RenderingIntent(string name) => $"The rendering intent {name} is not one of the four standard ones.";
    public const string TransparencyGroup = "A page or form has a transparency group.";
    public const string PostScriptObject = "A PostScript XObject is used.";
    public const string ReferenceXObject = "A form XObject has a /Ref entry.";
    public const string TransferFunction = "A graphics state sets a transfer function.";
    public const string Halftone = "A graphics state sets a halftone.";
    public static string BlendMode(string? mode) => $"The blend mode {mode} needs transparency.";
    public const string Opacity = "A constant opacity below 1 needs transparency.";
    public const string SoftMask = "A soft mask needs transparency.";
    public const string ImageTransparency = "An image has a soft mask or alpha data.";
    public const string Opi = "An object has an /OPI entry.";
    public const string Interpolate = "An image sets /Interpolate to true.";
    public const string Alternates = "An image has /Alternates.";
    public const string Jpx = "An image uses JPEG 2000, which PDF 1.4 does not have.";
    public const string ContentUnreadable = "A content stream could not be read.";
    public static string SeparationDiffers(string name) => $"Separation {name} is defined more than once with different alternates.";

    public const string ProfileComponents = "An ICC profile stream has no usable /N.";
    public const string ProfileUnreadable = "An ICC profile could not be read.";
    public static string ProfileClass(string kind) => $"An ICC profile of class {kind} is not allowed.";
    public const string ProfileSpace = "An ICC profile does not match the colour count in /N.";
    public static string ProfileVersion(int version) => $"An ICC profile is version {version}, newer than this level allows.";

    public static string WidthDiffers(int code, double declared, double actual) =>
        F($"The width of {code} is {declared:0.##} but the font program says {actual:0.##}.");
    public const string FontNotEmbedded = "The font is not embedded.";
    public const string FontProgramUnreadable = "The embedded font program could not be read.";
    public const string FontFileSubtype = "The font file has no valid /Subtype.";
    public const string NoWidths = "The font has no /Widths or /FirstChar.";
    public const string CMapNotKnown = "The font names a CMap that is neither predefined nor embedded.";
    public const string NoSystemInfo = "The CIDFont has no /CIDSystemInfo.";
    public const string NoCidToGid = "A TrueType CIDFont has no /CIDToGIDMap.";
    public const string CidSetIncomplete = "The /CIDSet does not list every glyph shown.";
    public const string CharSetIncomplete = "The /CharSet does not list every glyph shown.";
    public const string SymbolicEncoding = "A symbolic TrueType font has an /Encoding.";
    public const string SymbolicCmap = "A symbolic TrueType font has no (3,0) or (1,0) cmap.";
    public const string TrueTypeEncoding = "A TrueType font must use WinAnsiEncoding or MacRomanEncoding.";
    public const string NoUnicode = "The font has no /ToUnicode and its text cannot be traced another way.";

    public static string AnnotationType(string? subtype) => subtype is null ? "An annotation has no subtype." : $"The annotation type {subtype} is not allowed.";
    public const string NoPrintFlag = "The Print flag of the annotation is not set.";
    public const string HiddenAnnotation = "The annotation is hidden, invisible or not shown on screen.";
    public const string NoAppearance = "The annotation has no normal appearance stream.";
    public const string AppearanceKeys = "The appearance dictionary has keys other than /N.";
    public const string ButtonAppearance = "The /N of a button widget must be a dictionary of states.";
    public const string AppearanceNotStream = "The /N of an annotation must be a stream.";
    public const string FieldTriggers = "A field or widget has an /AA entry.";
    public const string CatalogTriggers = "The catalog has an /AA entry.";
    public const string JavaScript = "JavaScript is used.";
    public static string ForbiddenAction(string type) => $"A {type} action is used.";
    public static string NamedAction(string? name) => $"The named action {name} is not allowed.";
    public const string NeedAppearances = "The form sets /NeedAppearances to true.";
    public const string Xfa = "The form has XFA data.";

    public const string NoMetadata = "The catalog has no /Metadata stream.";
    public const string XmpTooBig = "The XMP packet is too large to read.";
    public const string XmpNoRdf = "The XMP packet has no rdf:RDF element.";
    public const string XmpNotWellFormed = "The XMP packet is not well-formed XML.";
    public const string NoIdentification = "The XMP has no PDF/A identification (pdfaid:part).";
    public static string WrongPart(string found, int wanted) => $"The XMP says part {found}; part {wanted} is checked.";
    public const string NoRevision = "The XMP has no pdfaid:rev of 2020.";
    public static string WrongConformance(string? found, string wanted) => $"The XMP says conformance {found ?? "none"}; {wanted} is needed.";
    public static string NoExtensionSchema(string ns) => $"The XMP uses properties of {ns} with no extension schema.";
    public static string InfoKey(string key) => $"The information dictionary has /{key}, which this level does not allow.";
    public static string InfoDiffers(string key, string property) => $"/{key} does not match {property} in the XMP.";
    public const string NoConditionIdentifier = "An output intent has no /OutputConditionIdentifier.";
    public const string NoProfile = "A PDF/A output intent has no /DestOutputProfile.";
    public const string ProfilesDiffer = "The output intents use different profiles.";
    public const string OptionalContent = "The catalog has /OCProperties.";
    public const string NoDefaultConfig = "The optional content has no default configuration.";
    public const string ConfigName = "An optional content configuration has no /Name.";
    public const string ConfigNameTwice = "Two optional content configurations have the same name.";
    public const string AutoState = "An optional content configuration has /AS.";
    public const string OrderIncomplete = "The /Order of a configuration leaves out some groups.";

    public const string Producer = "Lazy PDF";
    public const string NeedsPassword = "The file needs a password.";
    public const string Unreadable = "The file could not be read.";
    public const string NoRights = "The file's permissions do not allow changing it, so it cannot be converted.";
    public const string DynamicXfa = "The file is a dynamic XFA form, which has no pages of its own to keep.";
    public static string Transparency(IEnumerable<string> reasons) =>
        $"PDF/A-1 does not allow transparency and it cannot be flattened here. {string.Join(' ', reasons)} Convert to PDF/A-2 or later instead.";
    public static string CouldNotRewrite(string detail) => $"The file could not be rewritten: {detail}";

    public const string EncryptionRemoved = "The encryption was removed.";
    public const string SignaturesBroken = "The file was signed; its signatures no longer verify.";
    public static string ActionsRemoved(int count) => F($"{count} actions or scripts were removed.");
    public static string AnnotationsRemoved(int count) => F($"{count} annotations of a kind this level does not allow were removed.");
    public static string FlagsSet(int count) => F($"The print and visibility flags of {count} annotations were corrected.");
    public static string AppearancesDrawn(int count) => F($"Appearances were drawn for {count} annotations.");
    public static string FieldsDrawn(int count) => F($"Appearances were drawn for {count} form fields.");
    public static string IntegersClamped(int count) => F($"{count} integers beyond 32 bits were cut to the limit.");
    public static string GroupsRemoved(int count) => F($"{count} transparency groups were removed; nothing on the pages needed them.");
    public const string XfaRemoved = "The XFA data was removed; the form keeps its normal fields.";
    public static string StreamsRecoded(int count) => F($"{count} streams were recompressed without LZW.");
    public const string LayersRemoved = "The layers were removed; hidden layers now show.";
    public static string AttachmentsRemoved(int count) => F($"{count} embedded files were removed.");
    public static string AttachmentsDescribed(int count) => F($"{count} embedded files were given a relationship and a type.");
    public const string IntentAdded = "An sRGB output intent was added.";
    public static string MetadataWritten(PdfALevel level) => $"The XMP metadata now identifies the file as {level.Name()}.";
    public static string FontsEmbedded(int count) => F($"{count} fonts were embedded.");
    public static string FontsCorrected(int count) => F($"{count} fonts were corrected.");
}
