import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/PdfUaText.cs: the sentences of the PDF/UA-1 check. Places are the "where" of an
// issue and come from PdfAText.

public enum PdfUaText {
    public static var noMarkInfo: String { L10n.t("The catalog has no /MarkInfo with /Marked true.") }
    public static var suspects: String { L10n.t("The catalog says the tags are suspect (/Suspects true).") }
    public static var noStructTree: String { L10n.t("The file has no structure tree.") }
    public static var structTreeTooBig: String { L10n.t("The structure tree is too large to check.") }
    public static var untagged: String { L10n.t("Content is neither tagged nor marked as an artifact.") }
    public static var artifactInTagged: String { L10n.t("An artifact sits inside tagged content.") }
    public static var taggedInArtifact: String { L10n.t("Tagged content sits inside an artifact.") }

    public static func notMapped(_ type: String) -> String { L10n.t("The structure type {0} is not a standard type and the role map does not lead to one.", type) }
    public static func roleMapCircular(_ type: String) -> String { L10n.t("The role map leads {0} in a circle or through too many steps.", type) }
    public static func standardRemapped(_ type: String, _ target: String) -> String { L10n.t("The standard structure type {0} is remapped to {1}.", type, target) }

    public static var noMetadata: String { L10n.t("The catalog has no /Metadata stream.") }
    public static var noIdentifier: String { L10n.t("The XMP metadata does not have pdfuaid:part with the value 1.") }
    public static var noTitle: String { L10n.t("The XMP metadata has no dc:title.") }
    public static var titleNotShown: String { L10n.t("The viewer preferences do not set /DisplayDocTitle to true.") }

    public static func misnested(_ type: String, _ parent: String) -> String { L10n.t("{0} is not allowed in {1}.", type, parent) }
    public static func misnestedTop(_ type: String) -> String { L10n.t("{0} is not allowed at the top of the tree.", type) }

    public static var noLanguage: String { L10n.t("The catalog has no valid /Lang.") }
    public static var textLanguage: String { L10n.t("No natural language is set in the catalog or on the top structure elements.") }
    public static func badLanguage(_ value: String) -> String { L10n.t("The language {0} is not a valid language tag.", value) }

    public static func noAlt(_ type: String) -> String { L10n.t("A {0} element has neither /Alt nor /ActualText.", type) }
    public static func firstHeading(_ level: Int) -> String { L10n.t("The first numbered heading is H{0}; it must be H1.", level) }
    public static func headingSkipped(_ level: Int, _ previous: Int) -> String { L10n.t("Heading H{0} follows H{1}, skipping a level.", level, previous) }
    public static var headingMixed: String { L10n.t("The document uses both H and numbered headings.") }
    public static var noteId: String { L10n.t("A Note element has no /ID.") }
    public static func noteIdTwice(_ id: String) -> String { L10n.t("The Note /ID {0} is used twice.", id) }

    public static var configName: String { L10n.t("An optional content configuration has no /Name.") }
    public static var configAutoState: String { L10n.t("An optional content configuration has /AS.") }
    public static var fileSpec: String { L10n.t("A file specification of an embedded file lacks /F or /UF.") }
    public static var xfa: String { L10n.t("The form is a dynamic XFA form.") }
    public static var encrypted: String { L10n.t("The security settings do not allow assistive technology to extract text.") }

    public static func annotationUntagged(_ subtype: String) -> String { L10n.t("A {0} annotation is not part of the structure tree.", subtype) }
    public static func annotationTag(_ subtype: String, _ expected: String, _ found: String) -> String { L10n.t("A {0} annotation sits in a {2} element; it needs {1}.", subtype, expected, found) }
    public static func annotationContents(_ subtype: String) -> String { L10n.t("A {0} annotation has no /Contents.", subtype) }
    public static var widgetTooltip: String { L10n.t("A form field has no /TU.") }
    public static var tabOrder: String { L10n.t("The page has annotations and its tab order does not follow the structure.") }

    public static var referenceXObject: String { L10n.t("A form XObject has a /Ref entry.") }
    public static var postScriptXObject: String { L10n.t("The file has a PostScript XObject.") }

    public static var fontNotEmbedded: String { L10n.t("The font is not embedded.") }
    public static var fontNoUnicode: String { L10n.t("The font has characters that do not map to Unicode.") }
}
