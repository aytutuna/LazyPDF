import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/EditContent/Looks.cs: how the text being typed looks on the page, and the colours offered
// for text and shapes. Windows picks an installed family from the font's name; here the names come in as a list so that
// the arithmetic builds without CoreText.

public enum EditorLook {
    /// The look of a whole block: its first glyph's font and colour at the size the block reports.
    static func of(_ text: TextObject, installed: [String] = []) -> OverlayTextLook {
        OverlayTextLook(family: familyOf(text.font, installed: installed), size: text.size, bold: text.font?.isBold ?? false,
                        italic: text.font?.isItalic ?? false, color: color(text.color), alignment: alignment(text.alignment))
    }

    /// The look of one line of the block: its first glyph, not the block's.
    static func of(_ text: TextObject, line: GlyphLook?, installed: [String] = []) -> OverlayTextLook {
        guard let line else { return of(text, installed: installed) }
        return OverlayTextLook(family: familyOf(line.font, installed: installed), size: line.userSize, bold: line.font.isBold,
                               italic: line.font.isItalic, color: color(line.color), alignment: alignment(text.alignment))
    }

    /// The installed family that starts the font's name ("Arial-BoldMT" is Arial), else one of the three base families.
    static func familyOf(_ font: PdfFont?, installed: [String] = []) -> String {
        if let found = installedFamily(font, installed) { return found }
        guard let font else { return "Helvetica" }
        return font.isFixedPitch ? "Courier" : font.isSerif ? "Times" : "Helvetica"
    }

    /// The name shown for a font: the installed family it belongs to, else its own name.
    static func nameOf(_ font: PdfFont?, installed: [String] = []) -> String {
        installedFamily(font, installed) ?? font?.name ?? ""
    }

    static func color(_ color: RgbColor) -> OverlayColor {
        OverlayColor(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }

    static func alignment(_ alignment: LazyPDFKit.TextAlignment) -> TextAlign {
        switch alignment {
        case .center: return .center
        case .right: return .trailing
        case .justify: return .justified
        case .left: return .leading
        }
    }

    // The longest family whose name the font's name starts with.
    private static func installedFamily(_ font: PdfFont?, _ installed: [String]) -> String? {
        let name = squash(font?.name ?? "")
        return installed
            .filter { squash($0).count > 2 && name.hasPrefix(squash($0)) }
            .max { $0.count < $1.count }
    }

    private static func squash(_ name: String) -> String {
        String(name.filter { $0.isLetter || $0.isNumber }.lowercased())
    }
}

/// The colours offered for text and shapes.
public enum Palette {
    public static var colors: [(name: String, color: RgbColor)] {
        [
            (L10n.t("Black"), RgbColor(0, 0, 0)),
            (L10n.t("Grey"), RgbColor(110, 110, 110)),
            (L10n.t("White"), RgbColor(255, 255, 255)),
            (L10n.t("Red"), RgbColor(200, 30, 30)),
            (L10n.t("Orange"), RgbColor(235, 125, 20)),
            (L10n.t("Yellow"), RgbColor(240, 200, 20)),
            (L10n.t("Green"), RgbColor(40, 150, 60)),
            (L10n.t("Blue"), RgbColor(25, 100, 200)),
            (L10n.t("Purple"), RgbColor(130, 60, 170)),
        ]
    }
}
