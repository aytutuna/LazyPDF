import Foundation

// Twin of windows/LazyPDF.Core/Compare/CompareText.cs: the words the comparison shows.

public enum CompareText {
    public static func kindName(_ kind: ChangeKind) -> String {
        switch kind {
        case .added: return L10n.t("Added")
        case .removed: return L10n.t("Removed")
        case .moved: return L10n.t("Moved")
        default: return L10n.t("Changed")
        }
    }

    public static func areaName(_ area: ChangeArea) -> String {
        switch area {
        case .text: return L10n.t("Text")
        case .format: return L10n.t("Format")
        case .image: return L10n.t("Picture")
        case .annotation: return L10n.t("Annotation")
        case .page: return L10n.t("Page")
        default: return L10n.t("Document")
        }
    }

    public static var title: String { L10n.t("Comparison") }

    public static var noDifferences: String { L10n.t("No differences found.") }

    public static var pages: String { L10n.t("Pages") }

    public static var legend: String { L10n.t("Green is added, red is removed, amber is changed or moved.") }

    public static var was: String { L10n.t("Was: ") }

    public static func movedFrom(_ page: Int) -> String { L10n.t("Moved from page {0}", page + 1) }

    public static var pageAdded: String { L10n.t("Page added") }

    public static var pageRemoved: String { L10n.t("Page removed") }

    public static var pageMoved: String { L10n.t("Page moved") }

    public static func pageSize(_ oldWidth: Double, _ oldHeight: Double, _ newWidth: Double, _ newHeight: Double) -> String {
        L10n.t("Size {0} x {1} pt to {2} x {3} pt", points(oldWidth), points(oldHeight), points(newWidth), points(newHeight))
    }

    private static func points(_ value: Double) -> String { digits(value, 1) }

    public static func pageRotation(_ from: Int, _ to: Int) -> String { L10n.t("Rotation {0} to {1} degrees", from, to) }

    public static func fontChange(_ from: String, _ to: String) -> String { L10n.t("Font {0} to {1}", from, to) }

    public static func sizeChange(_ from: Double, _ to: Double) -> String {
        L10n.t("Size {0} to {1}", digits(from, 2), digits(to, 2))
    }

    public static func colorChange(_ from: RgbColor, _ to: RgbColor) -> String { L10n.t("Colour {0} to {1}", hex(from), hex(to)) }

    private static func hex(_ c: RgbColor) -> String { String(format: "#%02X%02X%02X", Int(c.r), Int(c.g), Int(c.b)) }

    public static var imageMoved: String { L10n.t("Picture moved or resized") }

    public static var imageReplaced: String { L10n.t("Picture replaced") }

    public static var annotationText: String { L10n.t("Comment text") }

    public static var annotationPosition: String { L10n.t("Position") }

    public static var annotationColor: String { L10n.t("Colour") }

    public static var bookmark: String { L10n.t("Bookmark") }

    public static var bookmarkPage: String { L10n.t("Bookmark goes to another page") }

    public static var attachment: String { L10n.t("Attachment") }

    public static func formField(_ name: String) -> String { L10n.t("Form field {0}", name) }

    public static func metadata(_ field: String) -> String { field }

    public static var marksCapped: String { L10n.t("Only the first 5000 differences are marked.") }

    public static func changeCount(_ count: Int) -> String { L10n.plural(count, one: "{0} difference", other: "{0} differences") }

    public static func pageCounts(_ oldCount: Int, _ newCount: Int) -> String { L10n.t("{0} pages and {1} pages", oldCount, newCount) }

    // ToString("0.#") and ToString("0.##") under the invariant culture: the value is cut to 15 significant digits first,
    // then rounded half away from zero at `places` decimals.
    static func digits(_ value: Double, _ places: Int) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }
        let scientific = String(format: "%.14e", abs(value))
        let parts = scientific.split(separator: "e")
        var all = parts[0].filter { $0 != "." }.map { Int(String($0)) ?? 0 }
        let exponent = Int(parts[1]) ?? 0
        var whole = exponent + 1
        if whole < 0 {
            all = [Int](repeating: 0, count: -whole) + all
            whole = 0
        }
        while all.count < whole + places + 1 { all.append(0) }
        let keep = whole + places
        var carry = all[keep] >= 5
        all = Array(all[0..<keep])
        var at = keep - 1
        while carry {
            if at < 0 {
                all.insert(1, at: 0)
                whole += 1
                carry = false
            } else if all[at] == 9 {
                all[at] = 0
                at -= 1
            } else {
                all[at] += 1
                carry = false
            }
        }
        var integer = all[0..<whole].map(String.init).joined()
        var fraction = all[whole...].map(String.init).joined()
        while fraction.hasSuffix("0") { fraction.removeLast() }
        if integer.isEmpty { integer = "0" }
        return sign + (fraction.isEmpty ? integer : integer + "." + fraction)
    }
}
