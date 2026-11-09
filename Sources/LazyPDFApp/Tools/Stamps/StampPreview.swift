import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/StampPreview.cs: draws a draft as marks on a page's overlay, in page points, close to
// what the engine will write. Windows measures text with WPF; here the width comes from the standard fonts' own tables, which
// is what the engine uses for the three base families, and any other family is measured as Helvetica.

public enum StampPreview {
    // A background sits behind the text in the file; drawn in front it has to stay faint.
    private static let backgroundCeiling = 0.25
    private static let lineHeight = 1.15
    private static let token = try! NSRegularExpression(pattern: #"\{(\w+)(?::([^}]*))?\}"#)

    public static let prefix = "stamps.preview."

    /// The page's share of the draft, empty when the draft puts nothing on it. `ordinal` is how many stamped pages come before
    /// this one, which Bates numbers count.
    public static func build(_ draft: StampDraft, picture: PdfRgbaImage?, page: Int, pageCount: Int, ordinal: Int, size: ViewSize,
                             fileName: String, now: DateTimeOffset) -> [OverlayItem] {
        var items: [OverlayItem] = []
        if let mark = draft.watermark {
            watermark(&items, mark, picture, size)
        } else if let back = draft.background {
            background(&items, back, picture, size)
        } else if let spec = draft.headerFooter {
            headerFooter(&items, spec, page, pageCount, ordinal, size, fileName, now)
        }
        return items
    }

    /// Fills in `{page}`, `{pages}`, `{date}`, `{file}` and `{bates}`; anything else stays as typed.
    public static func expand(_ template: String, page: Int, pages: Int, bates: String?, fileName: String, date: DateTimeOffset,
                              dateFormat: String, culture: CultureInfo = .invariantCulture) -> String {
        let source = NSString(string: template)
        var result = ""
        var last = 0
        for match in token.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let whole = source.substring(with: match.range)
            let argument = match.range(at: 2).location == NSNotFound ? nil : source.substring(with: match.range(at: 2))
            switch source.substring(with: match.range(at: 1)) {
            case "page": result += String(page)
            case "pages": result += String(pages)
            case "file": result += fileName
            case "bates": result += bates ?? whole
            case "date":
                let format = argument.flatMap { $0.isEmpty ? nil : $0 } ?? dateFormat
                result += (try? date.toString(format, culture)) ?? whole
            default: result += whole
            }
        }
        return result + source.substring(from: last)
    }

    /// Where the engine puts a background picture: scaled as the fit says and centred on the page.
    public static func fitted(_ fit: BackgroundFit, _ width: Double, _ height: Double, _ page: ViewSize) -> ViewRect {
        var sx = page.width / width, sy = page.height / height
        if fit == .cover {
            sx = Swift.max(sx, sy)
            sy = sx
        } else if fit == .contain {
            sx = Swift.min(sx, sy)
            sy = sx
        }
        let w = width * sx, h = height * sy
        return ViewRect((page.width - w) / 2, (page.height - h) / 2, w, h)
    }

    // MARK: Text

    private static func color(_ c: StampColor) -> OverlayColor {
        OverlayColor(red: Swift.min(Swift.max(c.r, 0), 1), green: Swift.min(Swift.max(c.g, 0), 1), blue: Swift.min(Swift.max(c.b, 0), 1))
    }

    private static func look(_ family: String, _ style: FontStyles, _ size: Double, _ c: StampColor, _ alignment: TextAlign) -> OverlayTextLook {
        OverlayTextLook(family: family, size: size, bold: style.contains(.bold), italic: style.contains(.italic), color: color(c), alignment: alignment)
    }

    static func width(_ text: String, _ family: String, _ style: FontStyles, _ size: Double) -> Double {
        let lower = family.lowercased()
        let base = lower.hasPrefix("times") ? "Times" : lower.hasPrefix("courier") ? "Courier" : "Helvetica"
        let face = base + (style.contains(.bold) ? "-Bold" : "") + (style.contains(.italic) ? "Italic" : "")
        guard let standard = Standard14.find(face) else { return Double(text.unicodeScalars.count) * size * 0.55 }
        var units = 0.0
        for scalar in text.unicodeScalars where scalar.value >= 0x20 {
            let name = scalar.value < 256 ? PdfEncodings.winAnsi[Int(scalar.value)] : nil
            units += Double(name.flatMap { standard.widthOf($0) } ?? 556)
        }
        return units * size / 1000
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Kinds

    private static func watermark(_ items: inout [OverlayItem], _ spec: WatermarkSpec, _ picture: PdfRgbaImage?, _ page: ViewSize) {
        let wanted = spec.scale * page.width
        var box = ViewSize.zero
        var shape: OverlayShape?
        if let text = spec.text, !text.isEmpty, picture == nil {
            let rows = lines(text)
            let widest = rows.map { width($0, spec.fontFamily, spec.fontStyle, 100) }.max() ?? 0
            let size = widest > 0 ? Swift.min(Swift.max(wanted / widest * 100, 1), 1000) : 12
            let across = rows.map { width($0, spec.fontFamily, spec.fontStyle, size) }.max() ?? 0
            box = ViewSize(across, size * lineHeight * Double(rows.count))
            shape = .text(OverlayText(rows.joined(separator: "\n"), at: ViewPoint.zero, anchor: .center,
                                      look: look(spec.fontFamily, spec.fontStyle, size, spec.color, .center)))
        } else if let picture, picture.width > 0 {
            box = ViewSize(wanted, wanted * Double(picture.height) / Double(picture.width))
            shape = .picture(OverlayPicture(picture, rect: ViewRect.empty))
        }
        guard let shape else { return }
        let column = spec.anchor.rawValue % 3, row = spec.anchor.rawValue / 3
        let x = (column == 0 ? 0 : column == 1 ? (page.width - box.width) / 2 : page.width - box.width) + spec.offsetX
        let y = (row == 0 ? 0 : row == 1 ? (page.height - box.height) / 2 : page.height - box.height) + spec.offsetY
        let placed: OverlayShape
        switch shape {
        case .text(var text):
            text.at = ViewPoint(x + box.width / 2, y + box.height / 2)
            placed = .text(text)
        case .picture(let made):
            placed = .picture(OverlayPicture(made.image, rect: ViewRect(x, y, box.width, box.height)))
        default:
            placed = shape
        }
        items.append(OverlayItem(prefix + String(items.count), placed, opacity: spec.opacity, rotation: -spec.rotation))
    }

    private static func background(_ items: inout [OverlayItem], _ spec: BackgroundSpec, _ picture: PdfRgbaImage?, _ page: ViewSize) {
        let opacity = Swift.min(spec.opacity, backgroundCeiling)
        if let fill = spec.color {
            items.append(OverlayItem(prefix + String(items.count), .rect(ViewRect(0, 0, page.width, page.height)),
                                     style: OverlayStyle(fill: color(fill)), opacity: opacity))
        }
        guard let picture, picture.width > 0, picture.height > 0 else { return }
        let box = fitted(spec.fit, Double(picture.width), Double(picture.height), page)
        items.append(OverlayItem(prefix + String(items.count), .picture(OverlayPicture(picture, rect: box)), opacity: opacity))
    }

    private static func headerFooter(_ items: inout [OverlayItem], _ spec: HeaderFooterSpec, _ page: Int, _ pageCount: Int, _ ordinal: Int,
                                     _ size: ViewSize, _ fileName: String, _ now: DateTimeOffset) {
        let bates = spec.bates.map { $0.format($0.start + ordinal) }
        let number = spec.startNumber + page
        let last = spec.startNumber + pageCount - 1
        func slot(_ template: String) -> String {
            expand(template, page: number, pages: last, bates: bates, fileName: fileName, date: now, dateFormat: spec.dateFormat, culture: spec.culture)
        }
        func band(_ band: HeaderFooterBand, header: Bool) {
            let texts = [slot(band.left), slot(band.center), slot(band.right)]
            for (i, text) in texts.enumerated() where !text.isEmpty {
                let across = width(text, spec.fontFamily, spec.fontStyle, spec.fontSize)
                let high = spec.fontSize * lineHeight
                let x = i == 0 ? spec.marginX : i == 1 ? (size.width - across) / 2 : size.width - spec.marginX - across
                let y = header ? spec.marginTop : size.height - spec.marginBottom - high
                let shown = OverlayText(text, at: ViewPoint(x, y), look: look(spec.fontFamily, spec.fontStyle, spec.fontSize, spec.color, .leading))
                items.append(OverlayItem(prefix + String(items.count), .text(shown)))
            }
        }
        band(spec.header, header: true)
        band(spec.footer, header: false)
    }
}
