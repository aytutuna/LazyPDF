import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/FillSign/FillSignPlacement.cs: where a signature or a line of text goes on a page, and
// putting it there. Boxes are in page space, y down.

@MainActor
public enum FillSignPlacement {
    public static let signatureWidth = 150.0
    public static let initialsWidth = 60.0

    /// A box of the given width centred on the click, kept on the page.
    nonisolated public static func around(_ click: ViewPoint, _ width: Double, _ aspect: Double, _ page: ViewSize) -> DisplayRect {
        let w = min(width, page.width), h = w / aspect
        return DisplayRect(clamp(click.x - w / 2, 0, page.width - w), clamp(click.y - h / 2, 0, max(0, page.height - h)), w, h)
    }

    /// The largest box with the picture's proportions that fits the drag from one corner to the other.
    nonisolated public static func fromDrag(_ from: ViewPoint, _ to: ViewPoint, _ aspect: Double, _ page: ViewSize) -> DisplayRect {
        var w = abs(to.x - from.x), h = abs(to.y - from.y)
        if w < h * aspect { h = w / aspect } else { w = h * aspect }
        let x = to.x < from.x ? from.x - w : from.x, y = to.y < from.y ? from.y - h : from.y
        return DisplayRect(clamp(x, 0, max(0, page.width - w)), clamp(y, 0, max(0, page.height - h)), w, h)
    }

    nonisolated private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    /// Why the file may not be added to; nil when it may.
    public static func refusal(_ document: PdfDocument) -> Problem? {
        PdfAnnotations.canAnnotate(document) ? nil
            : Problem(L10n.t("This file cannot be changed"), L10n.t("Its permissions do not allow it. Open it with the owner password."))
    }

    /// What adding to the file does to its signatures; nil when it has none.
    public static func caution(_ document: PdfDocument) -> String? {
        document.isSigned ? L10n.t("This file is signed, so changing it breaks the signatures.") : nil
    }

    @discardableResult
    public static func placeImage(_ tab: DocumentTab, _ page: Int, _ box: DisplayRect, _ image: PdfRgbaImage, _ now: DateTimeOffset) throws -> Bool {
        let document = tab.document
        let target = document.pages[page]
        let rect = PageGeometry(target).toUser(box)
        let stamp = try PdfAnnotationWriter(document).addImageStamp(target, asShown(rect, box), image.width, image.height, image.rgba,
                                                                    info: AnnotationInfo(date: now))
        turnToPage(document, stamp, rect, target.rotate)
        return try tab.commit(L10n.t("Place signature"))
    }

    /// One or more lines of text with its left edge at the click, centred on it vertically.
    @discardableResult
    public static func placeText(_ tab: DocumentTab, _ fonts: FontSource, _ page: Int, _ click: ViewPoint, _ text: String, _ size: Double,
                                 _ now: DateTimeOffset) throws -> Bool {
        let document = tab.document
        let target = document.pages[page]
        let geometry = PageGeometry(target)
        let (width, height) = measure(text, size)
        let box = DisplayRect(clamp(click.x, 0, max(0, geometry.width - width)),
                              clamp(click.y - height / 2, 0, max(0, geometry.height - height)),
                              min(width, geometry.width), min(height, geometry.height))
        let rect = geometry.toUser(box)
        let note = try PdfAnnotationWriter(document, fonts).addFreeText(target, asShown(rect, box), text, font: FreeTextStyle(family: "Helvetica", size: size),
                                                                       info: AnnotationInfo(date: now))
        turnToPage(document, note, rect, target.rotate)
        return try tab.commit(L10n.t("Place text"))
    }

    // On a page turned a quarter the user rectangle is the display box on its side. The appearance is drawn as the page shows it,
    // at the size of the display box, and its matrix turns it into the page's own space (ISO 32000-1 12.5.5).
    private static func asShown(_ user: PdfRect, _ box: DisplayRect) -> PdfRect {
        PdfRect(user.left, user.bottom, user.left + box.width, user.bottom + box.height)
    }

    private static func turnToPage(_ document: PdfDocument, _ annotation: PdfAnnotation, _ user: PdfRect, _ rotate: Int) {
        if rotate == 0 { return }
        let d = annotation.dictionary
        d["Rect"] = user.toArray()
        guard let form = document.resolve(document.dict(d, "AP")?["N"]) as? PdfStream else { return }
        let (a, b): (Double, Double) = rotate == 90 ? (0, 1) : rotate == 180 ? (-1, 0) : (0, -1)
        form.dictionary["Matrix"] = PdfArray([PdfNumber(a), PdfNumber(b), PdfNumber(-b), PdfNumber(a), PdfNumber(0), PdfNumber(0)])
    }

    // The box has to hold the text on its own lines, so it is measured with Helvetica, the face that is drawn, whose advances are
    // those of the Arial the Windows tool measures with.
    nonisolated static func measure(_ text: String, _ size: Double) -> (width: Double, height: Double) {
        let lines = text.components(separatedBy: "\n")
        let font = Standard14.find("Helvetica")
        let widest = lines.map { line in
            line.unicodeScalars.reduce(0.0) { $0 + advance($1, font) * size / 1000 }
        }.max() ?? 0
        return (widest.rounded(.up) + 8, (Double(lines.count) * size * 1.25).rounded(.up) + 4)
    }

    nonisolated private static func advance(_ scalar: Unicode.Scalar, _ font: Standard14?) -> Double {
        var scalar = scalar
        if scalar.value == 0x131 { return Double(font?.widthOf("dotlessi") ?? font?.widthOf("i") ?? 556) }
        // Letters outside WinAnsi are sized as their base letter, so ş measures as s.
        if scalar.value >= 256, let base = String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars.first, base.value < 256 {
            scalar = base
        }
        guard scalar.value >= 32, scalar.value < 256, let name = PdfEncodings.winAnsi[Int(scalar.value)],
              let width = font?.widthOf(name) else { return 556 }
        return Double(width)
    }
}
