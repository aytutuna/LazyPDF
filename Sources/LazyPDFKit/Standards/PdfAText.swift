import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAText.cs: the sentences of the PDF/A checks and conversion. Places are the
// "where" of an issue.

public enum PdfAText {
    public static var header: String { L10n.t("File header") }
    public static var trailer: String { L10n.t("Trailer") }
    public static var xref: String { L10n.t("Cross-reference") }
    public static var catalog: String { L10n.t("Catalog") }
    public static var metadata: String { L10n.t("Metadata") }
    public static var info: String { L10n.t("Document information") }
    public static var form: String { L10n.t("Form") }
    public static var outputIntent: String { L10n.t("Output intent") }

    public static func pageName(_ page: Int) -> String { L10n.t("Page {0}", page) }
    public static func objectName(_ number: Int) -> String { L10n.t("Object {0}", number) }
    public static func annotationName(_ page: Int, _ index: Int) -> String { L10n.t("Page {0}, annotation {1}", page, index) }
    public static func fontName(_ name: String) -> String { name.isEmpty ? L10n.t("Font") : L10n.t("Font {0}", name) }

    public static var bytesBeforeHeader: String { L10n.t("Bytes come before the %PDF header.") }
    public static var headerMissing: String { L10n.t("The header line is missing.") }
    public static func headerVersion(_ version: String) -> String { L10n.t("The header names version {0}; it must be 1.0 to 1.7.", version) }
    public static func headerVersion4(_ version: String) -> String { L10n.t("The header names version {0}; it must be 2.0.", version) }
    public static var headerComment: String { L10n.t("The second line must be a comment of four bytes above 127.") }
    public static var noEof: String { L10n.t("The file does not end with %%EOF.") }
    public static var dataAfterEof: String { L10n.t("Data follows the last %%EOF.") }
    public static var noId: String { L10n.t("The trailer has no /ID of two strings.") }
    public static var encrypted: String { L10n.t("The file is encrypted.") }
    public static var xrefDamaged: String { L10n.t("The cross-reference data is damaged and had to be rebuilt.") }
    public static var xrefStream: String { L10n.t("The file uses a cross-reference stream, which PDF 1.4 does not have.") }
    public static var objectStreams: String { L10n.t("The file uses object streams, which PDF 1.4 does not have.") }
    public static var streamKeyword: String { L10n.t("The stream keyword must be followed by CRLF or LF.") }
    public static var streamLength: String { L10n.t("The /Length of a stream does not match its data.") }
    public static func streamKey(_ key: String) -> String { L10n.t("A stream has the key /{0}, which is not allowed.", key) }
    public static var lzw: String { L10n.t("A stream uses the LZW filter.") }
    public static var cryptFilter: String { L10n.t("A stream uses the Crypt filter.") }
    public static func unknownFilter(_ name: String) -> String { L10n.t("A stream uses the filter {0}, which the standard does not list.", name) }
    public static var hexString: String { L10n.t("A hexadecimal string has an odd number of digits or a character that is not a hex digit.") }

    public static func stringTooLong(_ length: Int) -> String { L10n.t("A string is {0} bytes long, past the limit.", length) }
    public static var nameTooLong: String { L10n.t("A name is longer than 127 bytes.") }
    public static func integerTooBig(_ text: String) -> String { L10n.t("The integer {0} is outside the 32-bit range.", text) }
    public static func arrayTooLong(_ count: Int) -> String { L10n.t("An array has {0} elements; the limit is 8191.", count) }
    public static func dictionaryTooBig(_ count: Int) -> String { L10n.t("A dictionary has {0} entries; the limit is 4095.", count) }
    public static func realTooBig(_ text: String) -> String { L10n.t("The real number {0} is beyond 32767.", text) }
    public static var tooMuchContent: String { L10n.t("The page content is too large to check in full.") }
    public static var graphicsNesting: String { L10n.t("Graphics states are nested more than 28 deep.") }
    public static func tooManyColorants(_ limit: Int) -> String { L10n.t("A DeviceN space has more than {0} colorants.", limit) }

    public static var embeddedFile: String { L10n.t("The file embeds another file, which this level does not allow.") }
    public static var embeddedNotPdfA: String { L10n.t("An embedded file is not a PDF/A file.") }
    public static var noRelationship: String { L10n.t("A file specification has no /AFRelationship.") }
    public static var noMimeType: String { L10n.t("An embedded file stream has no /Subtype giving its MIME type.") }

    public static func deviceColor(_ family: String) -> String { L10n.t("{0} is used and the file has no output intent or default space for it.", family) }
    public static func unknownOperator(_ name: String) -> String { L10n.t("The content uses the operator {0}, which the standard does not define.", name) }
    public static func renderingIntent(_ name: String) -> String { L10n.t("The rendering intent {0} is not one of the four standard ones.", name) }
    public static var transparencyGroup: String { L10n.t("A page or form has a transparency group.") }
    public static var postScriptObject: String { L10n.t("A PostScript XObject is used.") }
    public static var referenceXObject: String { L10n.t("A form XObject has a /Ref entry.") }
    public static var transferFunction: String { L10n.t("A graphics state sets a transfer function.") }
    public static var halftone: String { L10n.t("A graphics state sets a halftone.") }
    public static func blendMode(_ mode: String?) -> String { L10n.t("The blend mode {0} needs transparency.", mode ?? "") }
    public static func unknownBlendMode(_ mode: String) -> String { L10n.t("The blend mode {0} is not one of the standard ones.", mode) }
    public static var opacity: String { L10n.t("A constant opacity below 1 needs transparency.") }
    public static var softMask: String { L10n.t("A soft mask needs transparency.") }
    public static var imageTransparency: String { L10n.t("An image has a soft mask or alpha data.") }
    public static var opi: String { L10n.t("An object has an /OPI entry.") }
    public static var interpolate: String { L10n.t("An image sets /Interpolate to true.") }
    public static var alternates: String { L10n.t("An image has /Alternates.") }
    public static var jpx: String { L10n.t("An image uses JPEG 2000, which PDF 1.4 does not have.") }
    public static var contentUnreadable: String { L10n.t("A content stream could not be read.") }
    public static func separationDiffers(_ name: String) -> String { L10n.t("Separation {0} is defined more than once with different alternates.", name) }

    public static var profileComponents: String { L10n.t("An ICC profile stream has no usable /N.") }
    public static var profileUnreadable: String { L10n.t("An ICC profile could not be read.") }
    public static func profileClass(_ kind: String) -> String { L10n.t("An ICC profile of class {0} is not allowed.", kind) }
    public static var profileSpace: String { L10n.t("An ICC profile does not match the colour count in /N.") }
    public static func profileVersion(_ version: Int) -> String { L10n.t("An ICC profile is version {0}, newer than this level allows.", version) }

    public static func widthDiffers(_ code: Int, _ declared: Double, _ actual: Double) -> String {
        L10n.t("The width of {0} is {1} but the font program says {2}.", code, twoDecimals(declared), twoDecimals(actual))
    }
    public static var fontNotEmbedded: String { L10n.t("The font is not embedded.") }
    public static var fontProgramUnreadable: String { L10n.t("The embedded font program could not be read.") }
    public static var fontFileSubtype: String { L10n.t("The font file has no valid /Subtype.") }
    public static var noWidths: String { L10n.t("The font has no /Widths or /FirstChar.") }
    public static var cMapNotKnown: String { L10n.t("The font names a CMap that is neither predefined nor embedded.") }
    public static var noSystemInfo: String { L10n.t("The CIDFont has no /CIDSystemInfo.") }
    public static var noCidToGid: String { L10n.t("A TrueType CIDFont has no /CIDToGIDMap.") }
    public static var cidSetIncomplete: String { L10n.t("The /CIDSet does not list every glyph shown or held in the font program.") }
    public static var charSetIncomplete: String { L10n.t("The /CharSet does not list every glyph shown or held in the font program.") }
    public static var cidSetMissing: String { L10n.t("A subset CIDFont has no /CIDSet.") }
    public static var charSetMissing: String { L10n.t("A subset Type 1 font has no /CharSet.") }
    public static var symbolicEncoding: String { L10n.t("A symbolic TrueType font has an /Encoding.") }
    public static var symbolicCmap: String { L10n.t("A symbolic TrueType font has no (3,0) or (1,0) cmap.") }
    public static var trueTypeEncoding: String { L10n.t("A TrueType font must use WinAnsiEncoding or MacRomanEncoding.") }
    public static var trueTypeDifferences: String { L10n.t("The /Differences of a TrueType font need names from the Adobe Glyph List and a (3,1) cmap.") }
    public static var noUnicode: String { L10n.t("The font has no /ToUnicode and its text cannot be traced another way.") }

    public static func annotationType(_ subtype: String?) -> String {
        guard let subtype else { return L10n.t("An annotation has no subtype.") }
        return L10n.t("The annotation type {0} is not allowed.", subtype)
    }
    public static var noPrintFlag: String { L10n.t("The Print flag of the annotation is not set.") }
    public static var hiddenAnnotation: String { L10n.t("The annotation is hidden, invisible or not shown on screen.") }
    public static var noAppearance: String { L10n.t("The annotation has no normal appearance stream.") }
    public static var appearanceKeys: String { L10n.t("The appearance dictionary has keys other than /N.") }
    public static var buttonAppearance: String { L10n.t("The /N of a button widget must be a dictionary of states.") }
    public static var appearanceNotStream: String { L10n.t("The /N of an annotation must be a stream.") }
    public static var fieldTriggers: String { L10n.t("A field or widget has an /AA entry.") }
    public static var catalogTriggers: String { L10n.t("The catalog has an /AA entry.") }
    public static var pageTriggers: String { L10n.t("A page has an /AA entry.") }
    public static var widgetAction: String { L10n.t("A widget has an /A entry.") }
    public static func triggerKey(_ key: String) -> String { L10n.t("An additional-actions dictionary has the key /{0}, which is not allowed.", key) }
    public static var javaScript: String { L10n.t("JavaScript is used.") }
    public static func forbiddenAction(_ type: String) -> String { L10n.t("A {0} action is used.", type) }
    public static func namedAction(_ name: String?) -> String { L10n.t("The named action {0} is not allowed.", name ?? "") }
    public static var outlines: String { L10n.t("Outlines") }
    public static var annotationColor: String { L10n.t("An annotation has /C or /IC and the output intent is not an RGB profile.") }
    public static var needsRendering: String { L10n.t("The catalog has /NeedsRendering.") }
    public static var needAppearances: String { L10n.t("The form sets /NeedAppearances to true.") }
    public static var xfa: String { L10n.t("The form has XFA data.") }

    public static var metadataFilter: String { L10n.t("The metadata stream has a /Filter.") }
    public static var noMetadata: String { L10n.t("The catalog has no /Metadata stream.") }
    public static var xmpTooBig: String { L10n.t("The XMP packet is too large to read.") }
    public static var xmpNoRdf: String { L10n.t("The XMP packet has no rdf:RDF element.") }
    public static var xmpNotWellFormed: String { L10n.t("The XMP packet is not well-formed XML.") }
    public static var noIdentification: String { L10n.t("The XMP has no PDF/A identification (pdfaid:part).") }
    public static func wrongPart(_ found: String, _ wanted: Int) -> String { L10n.t("The XMP says part {0}; part {1} is checked.", found, wanted) }
    public static var noRevision: String { L10n.t("The XMP has no pdfaid:rev of 2020.") }
    public static func wrongConformance(_ found: String?, _ wanted: String) -> String {
        L10n.t("The XMP says conformance {0}; {1} is needed.", found ?? L10n.t("none|no conformance"), wanted)
    }
    public static func noExtensionSchema(_ ns: String) -> String { L10n.t("The XMP uses properties of {0} with no extension schema.", ns) }
    public static func infoKey(_ key: String) -> String { L10n.t("The information dictionary has /{0}, which this level does not allow.", key) }
    public static func infoDiffers(_ key: String, _ property: String) -> String { L10n.t("/{0} does not match {1} in the XMP.", key, property) }
    public static var noConditionIdentifier: String { L10n.t("An output intent has no /OutputConditionIdentifier.") }
    public static var noProfile: String { L10n.t("A PDF/A output intent has no /DestOutputProfile.") }
    public static var profilesDiffer: String { L10n.t("The output intents use different profiles.") }
    public static var optionalContent: String { L10n.t("The catalog has /OCProperties.") }
    public static var noDefaultConfig: String { L10n.t("The optional content has no default configuration.") }
    public static var configName: String { L10n.t("An optional content configuration has no /Name.") }
    public static var configNameTwice: String { L10n.t("Two optional content configurations have the same name.") }
    public static var autoState: String { L10n.t("An optional content configuration has /AS.") }
    public static var orderIncomplete: String { L10n.t("The /Order of a configuration leaves out some groups.") }

    public static let producer = "Lazy PDF"
    public static var needsPassword: String { L10n.t("The file needs a password.") }
    public static var unreadable: String { L10n.t("The file could not be read.") }
    public static var noRights: String { L10n.t("The file's permissions do not allow changing it, so it cannot be converted.") }
    public static var dynamicXfa: String { L10n.t("The file is a dynamic XFA form, which has no pages of its own to keep.") }
    public static func transparency(_ reasons: [String]) -> String {
        L10n.t("PDF/A-1 does not allow transparency and it cannot be flattened here. {0} Convert to PDF/A-2 or later instead.", reasons.joined(separator: " "))
    }
    public static func couldNotRewrite(_ detail: String) -> String { L10n.t("The file could not be rewritten: {0}", detail) }

    public static var encryptionRemoved: String { L10n.t("The encryption was removed.") }
    public static var signaturesBroken: String { L10n.t("The file was signed; its signatures no longer verify.") }
    public static func actionsRemoved(_ count: Int) -> String { L10n.t("{0} actions or scripts were removed.", count) }
    public static func annotationsRemoved(_ count: Int) -> String { L10n.t("{0} annotations of a kind this level does not allow were removed.", count) }
    public static func flagsSet(_ count: Int) -> String { L10n.t("The print and visibility flags of {0} annotations were corrected.", count) }
    public static func appearancesDrawn(_ count: Int) -> String { L10n.t("Appearances were drawn for {0} annotations.", count) }
    public static func fieldsDrawn(_ count: Int) -> String { L10n.t("Appearances were drawn for {0} form fields.", count) }
    public static func integersClamped(_ count: Int) -> String { L10n.t("{0} integers beyond 32 bits were cut to the limit.", count) }
    public static func groupsRemoved(_ count: Int) -> String { L10n.t("{0} transparency groups were removed; nothing on the pages needed them.", count) }
    public static var xfaRemoved: String { L10n.t("The XFA data was removed; the form keeps its normal fields.") }
    public static func streamsRecoded(_ count: Int) -> String { L10n.t("{0} streams were recompressed without LZW.", count) }
    public static var layersRemoved: String { L10n.t("The layers were removed; hidden layers now show.") }
    public static func attachmentsRemoved(_ count: Int) -> String { L10n.t("{0} embedded files were removed.", count) }
    public static func attachmentsDescribed(_ count: Int) -> String { L10n.t("{0} embedded files were given a relationship and a type.", count) }
    public static var intentAdded: String { L10n.t("An sRGB output intent was added.") }
    public static func notDeclared(_ level: PdfALevel) -> String { L10n.t("The XMP metadata does not name {0}, because rules are still broken.", level.name()) }

    public static func metadataWritten(_ level: PdfALevel) -> String { L10n.t("The XMP metadata now identifies the file as {0}.", level.name()) }
    public static func fontsEmbedded(_ count: Int) -> String { L10n.t("{0} fonts were embedded.", count) }
    public static func fontsCorrected(_ count: Int) -> String { L10n.t("{0} fonts were corrected.", count) }

    // "0.##" with the invariant culture: the value is first cut to 15 significant digits, then halves round away from zero.
    private static func twoDecimals(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let text = String(format: "%.14e", abs(value))
        let parts = text.split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return "0" }
        let digits = parts[0].unicodeScalars.filter { $0 != "." }.map { Int($0.value) - 48 }
        let keep = exponent + 3
        var kept: [Int]
        if keep < 0 {
            kept = []
        } else if keep >= digits.count {
            kept = digits + [Int](repeating: 0, count: keep - digits.count)
        } else {
            kept = Array(digits[0..<keep])
            if digits[keep] >= 5 {
                var at = kept.count - 1
                while at >= 0 && kept[at] == 9 {
                    kept[at] = 0
                    at -= 1
                }
                if at >= 0 { kept[at] += 1 } else { kept.insert(1, at: 0) }
            }
        }
        while kept.count < 3 { kept.insert(0, at: 0) }
        let whole = kept[0..<(kept.count - 2)].map { String($0) }.joined()
        var fraction = kept[(kept.count - 2)...].map { String($0) }.joined()
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let sign = value < 0 ? "-" : ""
        return sign + whole + (fraction.isEmpty ? "" : "." + fraction)
    }
}
