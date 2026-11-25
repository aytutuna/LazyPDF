import Foundation
import LazyPDFKit

// Follows the TitleOf, DetailOf and name tables of windows/LazyPDF.App/Tools/Batch/BatchPanel.Steps.cs.

public enum BatchText {
    public static func title(_ kind: BatchStepKind) -> String {
        switch kind {
        case .ocr: return L10n.t("Make searchable")
        case .compress: return L10n.t("Make smaller")
        case .clean: return L10n.t("Clean for sharing")
        case .watermark: return L10n.t("Watermark")
        case .bates: return L10n.t("Bates numbers")
        case .pdfA: return L10n.t("PDF/A")
        case .pdfUa: return L10n.t("PDF/UA")
        }
    }

    public static func presetName(_ preset: BatchPreset) -> String {
        switch preset {
        case .small: return L10n.t("Small")
        case .balanced: return L10n.t("Balanced")
        case .highQuality: return L10n.t("High quality")
        }
    }

    public static func detail(_ step: BatchStep) -> String {
        switch step.kind {
        case .ocr: return L10n.t("Language {0}", step.text)
        case .compress: return presetName(step.preset)
        case .clean:
            return step.keepComments || step.keepForms || step.keepLinks || step.keepAttachments
                ? L10n.t("Keeps some private data") : L10n.t("Removes hidden and private data")
        case .watermark: return step.text.isEmpty ? L10n.t("No text yet") : step.text
        case .bates:
            return L10n.t("Starts at {0}", BatesSpec(prefix: step.text, suffix: step.suffix, digits: step.digits, start: step.start).format(step.start))
        case .pdfA: return step.level.level.name()
        case .pdfUa: return step.markPdfUa ? L10n.t("Checks and marks") : L10n.t("Checks only")
        }
    }

    public static func anchorName(_ anchor: StampAnchor) -> String {
        switch anchor {
        case .topLeft: return L10n.t("Top left")
        case .top: return L10n.t("Top")
        case .topRight: return L10n.t("Top right")
        case .left: return L10n.t("Left")
        case .center: return L10n.t("Center")
        case .right: return L10n.t("Right")
        case .bottomLeft: return L10n.t("Bottom left")
        case .bottom: return L10n.t("Bottom")
        case .bottomRight: return L10n.t("Bottom right")
        }
    }

    public static func placeName(_ place: BatesPlace) -> String {
        switch place {
        case .footerRight: return L10n.t("Footer, right")
        case .footerCenter: return L10n.t("Footer, center")
        case .footerLeft: return L10n.t("Footer, left")
        case .headerRight: return L10n.t("Header, right")
        case .headerCenter: return L10n.t("Header, center")
        case .headerLeft: return L10n.t("Header, left")
        }
    }
}
