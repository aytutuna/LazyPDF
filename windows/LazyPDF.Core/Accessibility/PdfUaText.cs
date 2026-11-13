namespace LazyPDF.Core;

/// <summary>The sentences of the PDF/UA-1 check. Places are the "where" of an issue and come from <see cref="PdfAText"/>.</summary>
public static class PdfUaText
{
    public static string NoMarkInfo => Loc.T("The catalog has no /MarkInfo with /Marked true.");
    public static string Suspects => Loc.T("The catalog says the tags are suspect (/Suspects true).");
    public static string NoStructTree => Loc.T("The file has no structure tree.");
    public static string StructTreeTooBig => Loc.T("The structure tree is too large to check.");
    public static string Untagged => Loc.T("Content is neither tagged nor marked as an artifact.");
    public static string ArtifactInTagged => Loc.T("An artifact sits inside tagged content.");
    public static string TaggedInArtifact => Loc.T("Tagged content sits inside an artifact.");

    public static string NotMapped(string type) => Loc.T("The structure type {0} is not a standard type and the role map does not lead to one.", type);
    public static string RoleMapCircular(string type) => Loc.T("The role map leads {0} in a circle or through too many steps.", type);
    public static string StandardRemapped(string type, string target) => Loc.T("The standard structure type {0} is remapped to {1}.", type, target);

    public static string NoMetadata => Loc.T("The catalog has no /Metadata stream.");
    public static string NoIdentifier => Loc.T("The XMP metadata does not have pdfuaid:part with the value 1.");
    public static string NoTitle => Loc.T("The XMP metadata has no dc:title.");
    public static string TitleNotShown => Loc.T("The viewer preferences do not set /DisplayDocTitle to true.");


    public static string Misnested(string type, string parent) => Loc.T("{0} is not allowed in {1}.", type, parent);
    public static string MisnestedTop(string type) => Loc.T("{0} is not allowed at the top of the tree.", type);

    public static string NoLanguage => Loc.T("The catalog has no valid /Lang.");
    public static string TextLanguage => Loc.T("No natural language is set in the catalog or on the top structure elements.");
    public static string BadLanguage(string value) => Loc.T("The language {0} is not a valid language tag.", value);

    public static string NoAlt(string type) => Loc.T("A {0} element has neither /Alt nor /ActualText.", type);
    public static string FirstHeading(int level) => Loc.T("The first numbered heading is H{0}; it must be H1.", level);
    public static string HeadingSkipped(int level, int previous) => Loc.T("Heading H{0} follows H{1}, skipping a level.", level, previous);
    public static string HeadingMixed => Loc.T("The document uses both H and numbered headings.");
    public static string NoteId => Loc.T("A Note element has no /ID.");
    public static string NoteIdTwice(string id) => Loc.T("The Note /ID {0} is used twice.", id);

    public static string ConfigName => Loc.T("An optional content configuration has no /Name.");
    public static string ConfigAutoState => Loc.T("An optional content configuration has /AS.");
    public static string FileSpec => Loc.T("A file specification of an embedded file lacks /F or /UF.");
    public static string Xfa => Loc.T("The form is a dynamic XFA form.");
    public static string Encrypted => Loc.T("The security settings do not allow assistive technology to extract text.");

    public static string AnnotationUntagged(string subtype) => Loc.T("A {0} annotation is not part of the structure tree.", subtype);
    public static string AnnotationTag(string subtype, string expected, string found) => Loc.T("A {0} annotation sits in a {2} element; it needs {1}.", subtype, expected, found);
    public static string AnnotationContents(string subtype) => Loc.T("A {0} annotation has no /Contents.", subtype);
    public static string WidgetTooltip => Loc.T("A form field has no /TU.");
    public static string TabOrder => Loc.T("The page has annotations and its tab order does not follow the structure.");

    public static string ReferenceXObject => Loc.T("A form XObject has a /Ref entry.");
    public static string PostScriptXObject => Loc.T("The file has a PostScript XObject.");

    public static string FontNotEmbedded => Loc.T("The font is not embedded.");
    public static string FontNoUnicode => Loc.T("The font has characters that do not map to Unicode.");
}
