import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeText.cs: the user-visible words of the optimizer and the sanitizer.

public enum OptimizeText {
    public static func stepName(_ kind: OptimizeStepKind) -> String {
        switch kind {
        case .removeUnreferenced: return L10n.t("Remove unused objects")
        case .objectStreams: return L10n.t("Pack objects")
        case .recompressStreams: return L10n.t("Recompress streams")
        case .convertOldFilters: return L10n.t("Replace old filters")
        case .removeDuplicates: return L10n.t("Merge duplicates")
        case .stripThumbnails: return L10n.t("Remove thumbnails")
        case .stripPieceInfo: return L10n.t("Remove application data")
        case .stripPrivateData: return L10n.t("Remove private keys")
        case .pruneResources: return L10n.t("Drop unused resources")
        case .downsampleImages: return L10n.t("Shrink pictures")
        case .bilevelImages: return L10n.t("Make black and white pictures 1-bit")
        case .subsetFonts: return L10n.t("Trim fonts")
        case .grayscale: return L10n.t("Convert to grayscale")
        }
    }

    public static func kindName(_ kind: SpaceKind) -> String {
        switch kind {
        case .images: return L10n.t("Pictures")
        case .fonts: return L10n.t("Fonts")
        case .content: return L10n.t("Page content")
        case .forms: return L10n.t("Forms")
        case .annotations: return L10n.t("Annotations")
        case .metadata: return L10n.t("Metadata")
        case .structure: return L10n.t("Structure")
        case .attachments: return L10n.t("Attachments")
        case .overhead: return L10n.t("File overhead")
        case .unreferenced: return L10n.t("Unused data")
        }
    }

    public static func itemName(_ item: SanitizeItem) -> String {
        switch item {
        case .javaScript: return L10n.t("JavaScript")
        case .launchActions: return L10n.t("Actions that launch or open other files")
        case .embeddedFiles: return L10n.t("Attached files")
        case .hiddenLayers: return L10n.t("Hidden layers")
        case .hiddenText: return L10n.t("Hidden text")
        case .invisibleText: return L10n.t("Invisible text")
        case .comments: return L10n.t("Comments and markup")
        case .formData: return L10n.t("Form data")
        case .metadata: return L10n.t("Document information and metadata")
        case .pieceInfo: return L10n.t("Application data")
        case .thumbnails: return L10n.t("Page thumbnails")
        case .previousVersions: return L10n.t("Earlier versions")
        case .searchIndexes: return L10n.t("Search and web capture data")
        case .externalLinks: return L10n.t("Links to the outside")
        case .filePaths: return L10n.t("File names and paths")
        case .signatures: return L10n.t("Digital signatures")
        }
    }

    public static var needsCodec: String { L10n.t("Pictures in JPEG and JPEG 2000 need the system codec and were left.") }
    public static var leftColor: String { L10n.t("Shadings, spot colors and patterns were left in color.") }
    public static var leftPartialFonts: String { L10n.t("Fonts with uses that could not be traced were left whole.") }
    public static var leftPartialImages: String { L10n.t("Pictures with uses that could not be traced were left at their size.") }
    public static var leftMixedText: String { L10n.t("Invisible text in a text object that also shows visible text was left.") }
}
