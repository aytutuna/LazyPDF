import Foundation

// Follows windows/LazyPDF.App/Tools/Measure/MeasureScale.cs.

public enum LengthUnit: CaseIterable {
    case millimetre, centimetre, metre, kilometre, inch, foot, yard, mile

    public var metres: Double {
        switch self {
        case .millimetre: return 0.001
        case .centimetre: return 0.01
        case .metre: return 1
        case .kilometre: return 1000
        case .inch: return 0.0254
        case .foot: return 0.3048
        case .yard: return 0.9144
        case .mile: return 1609.344
        }
    }

    public var symbol: String {
        switch self {
        case .millimetre: return "mm"
        case .centimetre: return "cm"
        case .metre: return "m"
        case .kilometre: return "km"
        case .inch: return "in"
        case .foot: return "ft"
        case .yard: return "yd"
        case .mile: return "mi"
        }
    }
}

public enum LengthUnits {
    public static let pointInMetres = 0.0254 / 72
}

/// "`page` of `pageUnit` on the page stand for `real` of `realUnit`", as a map scale is written.
public struct MeasureScale: Equatable {
    public var page: Double
    public var pageUnit: LengthUnit
    public var real: Double
    public var realUnit: LengthUnit

    /// The locale values are written in; a test sets another to see a group separator no standard font has.
    static var locale = Locale.autoupdatingCurrent

    public init(_ page: Double, _ pageUnit: LengthUnit, _ real: Double, _ realUnit: LengthUnit) {
        self.page = page
        self.pageUnit = pageUnit
        self.real = real
        self.realUnit = realUnit
    }

    public static let actual = MeasureScale(1, .millimetre, 1, .millimetre)

    public var isValid: Bool { page.isFinite && real.isFinite && page > 0 && real > 0 }

    /// How many real units one point of the page stands for.
    public var perPoint: Double { real / (page * pageUnit.metres / LengthUnits.pointInMetres) }

    public func length(_ points: Double) -> String {
        Self.number(points * perPoint) + " " + realUnit.symbol
    }

    public func area(_ squarePoints: Double) -> String {
        Self.number(squarePoints * perPoint * perPoint) + " " + realUnit.symbol + "²"
    }

    public var ratio: String {
        "\(Self.invariant(page, 4)) \(pageUnit.symbol) = \(Self.invariant(real, 4)) \(realUnit.symbol)"
    }

    private static func number(_ value: Double) -> String {
        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.locale = locale
        format.usesGroupingSeparator = true
        format.roundingMode = .halfUp
        format.minimumIntegerDigits = 1
        format.minimumFractionDigits = 0
        format.maximumFractionDigits = value >= 100 ? 0 : 2
        return format.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// At most `digits` decimals, a point for the separator and no grouping, whatever the locale.
    static func invariant(_ value: Double, _ digits: Int) -> String {
        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.locale = Locale(identifier: "en_US_POSIX")
        format.usesGroupingSeparator = false
        format.roundingMode = .halfUp
        format.minimumIntegerDigits = 1
        format.minimumFractionDigits = 0
        format.maximumFractionDigits = digits
        return format.string(from: NSNumber(value: value)) ?? String(value)
    }
}
