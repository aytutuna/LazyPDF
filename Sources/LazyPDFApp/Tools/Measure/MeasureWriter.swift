import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Measure/MeasureWriter.cs. Writes measurements as Line, PolyLine and Polygon annotations
// carrying a /Measure dictionary (ISO 32000-1 12.9, rectilinear), so other readers show and extend them with the same scale. A
// free text box beside each shows the value in any viewer.

public enum MeasureWriter {
    private static let blue = [0.05, 0.38, 0.75]

    public static func write(_ document: PdfDocument, _ items: [MeasureItem], _ scale: MeasureScale, author: String,
                             date: DateTimeOffset, fonts: FontSource? = nil) throws -> Int {
        // Nothing is written unless every page is still there, so a refusal leaves the document as it was.
        if items.contains(where: { $0.page < 0 || $0.page >= document.pages.count }) {
            throw ArgumentException("A measurement lies on a page that is gone.")
        }
        let writer = PdfAnnotationWriter(document, fonts)
        for item in items {
            let page = document.pages[item.page]
            let geometry = PageGeometry(page)
            let points: [PdfPoint] = item.points.map { geometry.toUser($0.x, $0.y) }
            let value = item.value(scale)
            let info = AnnotationInfo(author: author, contents: "\(item.title): \(value)", subject: item.title, date: date)
            let style = AnnotationStyle(color: blue, width: 1.5)

            let annotation: PdfAnnotation
            let intent: String
            switch item.kind {
            case .distance:
                annotation = try writer.addLine(page, points[0], points[1], style: style, info: info, start: .butt, end: .butt)
                intent = "LineDimension"
            case .perimeter:
                // Acrobat reads a closed polygon as an area, so the perimeter is an open polyline that comes back to its start.
                annotation = try writer.addPolyLine(page, points + [points[0]], style: style, info: info)
                intent = "PolyLineDimension"
            case .area:
                annotation = try writer.addPolygon(page, points, style: style, info: info)
                intent = "PolygonDimension"
            }
            annotation.dictionary["IT"] = PdfName(intent)
            annotation.dictionary["Measure"] = measureDictionary(scale, page.userUnit)

            try addLabel(document, writer, page, geometry, item.middle, value, author, date)
        }
        return items.count
    }

    // X converts the units of the page's user space to the real unit; D and A convert from the unit of X, so their factor is 1.
    private static func measureDictionary(_ scale: MeasureScale, _ userUnit: Double) -> PdfDictionary {
        let unit = scale.realUnit.symbol
        let measure = PdfDictionary()
        measure["Type"] = PdfName("Measure")
        measure["Subtype"] = PdfName("RL")
        measure["R"] = PdfText.toObject(scale.ratio)
        measure["X"] = formats(unit, scale.perPoint * userUnit)
        measure["Y"] = formats(unit, scale.perPoint * userUnit)
        measure["D"] = formats(unit, 1)
        measure["A"] = formats(unit + "²", 1)
        return measure
    }

    private static func formats(_ unit: String, _ factor: Double) -> PdfArray {
        let format = PdfDictionary()
        format["Type"] = PdfName("NumberFormat")
        format["U"] = PdfText.toObject(unit)
        format["C"] = PdfNumber(MeasureScale.invariant(factor, 12))
        format["F"] = PdfName("D")
        format["D"] = PdfNumber(100)
        return PdfArray([format])
    }

    // The box is drawn upright in its own space; on a turned page its form is turned back and its rectangle is the shown one.
    private static func addLabel(_ document: PdfDocument, _ writer: PdfAnnotationWriter, _ page: PdfPage, _ geometry: PageGeometry,
                                 _ at: ViewPoint, _ value: String, _ author: String, _ date: DateTimeOffset) throws {
        // No standard font has the no-break spaces a locale groups digits with.
        let text = value.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        let width = Double(text.count) * 5.5 + 8
        let shown = geometry.toUser(DisplayRect(at.x - width / 2, at.y - 7, width, 14))
        let upright = PdfRect(shown.left, shown.bottom, shown.left + width, shown.bottom + 14)
        let style = AnnotationStyle(color: [0, 0, 0], width: 0, fill: [1, 1, 1])
        let font = FreeTextStyle(size: 10, textColor: blue, alignment: 1)
        let label: PdfAnnotation
        do {
            label = try writer.addFreeText(page, upright, text, font: font, style: style, info: AnnotationInfo(author: author, date: date))
        } catch is InvalidOperationException {
            return
        }

        let turn: [Double]
        switch geometry.rotation {
        case 90: turn = [0, 1, -1, 0, 0, 0]
        case 180: turn = [-1, 0, 0, -1, 0, 0]
        case 270: turn = [0, -1, 1, 0, 0, 0]
        default: return
        }
        label.dictionary["Rect"] = shown.toArray()
        if let ap = label.dictionary["AP"] as? PdfDictionary, let form = document.resolve(ap["N"]) as? PdfStream {
            form.dictionary["Matrix"] = PdfArray(turn.map { PdfNumber($0) })
        }
    }
}
