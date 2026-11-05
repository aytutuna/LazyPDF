import Foundation

// Twin of windows/LazyPDF.Core/Content/GraphicsState.cs: the graphics state (ISO 32000-1 8.4) as it stands while an
// operator runs, with the text state (9.3), and the colours in it. The instances are the interpreter's own and
// change as it goes: copy what is needed during the callback.

/// A colour as 8-bit sRGB, converted without profiles (CMYK as (1-c)(1-k)).
public struct RgbColor: Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// A colour space (ISO 32000-1 8.6) as a content stream selects it.
public final class ColorSpaceInfo {
    private static let maxDepth = 8

    private init(_ family: String, _ components: Int, _ definition: PdfObject?, _ baseSpace: ColorSpaceInfo?, _ converter: SampleColorSpace?) {
        self.family = family
        self.components = components
        self.definition = definition
        self.base = baseSpace
        self.converter = converter
    }

    public static let deviceGray = device("DeviceGray", 1)
    public static let deviceRgb = device("DeviceRGB", 3)
    public static let deviceCmyk = device("DeviceCMYK", 4)

    /// DeviceGray, DeviceRGB, DeviceCMYK, CalGray, CalRGB, Lab, ICCBased, Indexed, Separation, DeviceN or Pattern.
    public let family: String

    /// Numbers a colour of this space has; for Pattern those of the underlying space (0 when it has none).
    public let components: Int

    /// The name or array as resolved from the file; nil for a device space selected by name.
    public let definition: PdfObject?

    /// The underlying space of an uncoloured pattern space.
    public let base: ColorSpaceInfo?

    let converter: SampleColorSpace?

    private static func device(_ family: String, _ components: Int) -> ColorSpaceInfo {
        let converter = try? SampleColorSpace.parse(PdfName(family), { $0 }, { _ in [] })
        return ColorSpaceInfo(family, components, nil, nil, converter)
    }

    static func create(_ document: PdfDocument, _ value: PdfObject?, _ depth: Int = 0) -> ColorSpaceInfo {
        let value = document.resolve(value)
        if depth > maxDepth { return deviceGray }
        if let name = value as? PdfName {
            switch name.value {
            case "DeviceRGB", "RGB", "CalRGB": return deviceRgb
            case "DeviceCMYK", "CMYK": return deviceCmyk
            case "Pattern": return ColorSpaceInfo("Pattern", 0, value, nil, nil)
            default: return deviceGray
            }
        }
        guard let array = value as? PdfArray, !array.items.isEmpty, let family = document.resolve(array.items[0]) as? PdfName else { return deviceGray }
        func item(_ i: Int) -> PdfObject? { i < array.items.count ? document.resolve(array.items[i]) : nil }
        if family.value == "Pattern" {
            let under = array.items.count > 1 ? create(document, array.items[1], depth + 1) : nil
            return ColorSpaceInfo("Pattern", under?.components ?? 0, value, under, nil)
        }
        let components: Int
        switch family.value {
        case "DeviceGray", "G", "CalGray", "Indexed", "I", "Separation": components = 1
        case "DeviceRGB", "RGB", "CalRGB", "Lab": components = 3
        case "DeviceCMYK", "CMYK": components = 4
        case "ICCBased":
            if let icc = item(1) as? PdfStream, let n = document.integer(icc.dictionary, "N"), n == 1 || n == 3 || n == 4 {
                components = n
            } else {
                components = 3
            }
        case "DeviceN":
            components = (item(1) as? PdfArray).map { Swift.min(Swift.max($0.items.count, 1), 32) } ?? 1
        default: components = 1
        }
        let fam: String
        switch family.value {
        case "G": fam = "DeviceGray"
        case "RGB": fam = "DeviceRGB"
        case "CMYK": fam = "DeviceCMYK"
        case "I": fam = "Indexed"
        default: fam = family.value
        }
        let converter = try? SampleColorSpace.parse(value, { document.resolve($0) }, { try document.data($0) })
        return ColorSpaceInfo(fam, components, value, nil, converter)
    }

    /// The colour every component zero (or one for the tint spaces) gives, what a space starts with (8.6.5.2).
    public func initialColor() -> [Double] {
        switch family {
        case "DeviceCMYK": return [0, 0, 0, 1]
        case "Separation", "DeviceN": return [Double](repeating: 1, count: components)
        default: return [Double](repeating: 0, count: components)
        }
    }

    public func toRgb(_ c: [Double]) -> RgbColor {
        var padded = [Double](repeating: 0, count: 32)
        for i in 0..<Swift.min(c.count, 32) { padded[i] = c[i] }
        var rgb: [UInt8] = [0, 0, 0]
        let fallback: ColorSpaceInfo
        switch components {
        case 3: fallback = Self.deviceRgb
        case 4: fallback = Self.deviceCmyk
        default: fallback = Self.deviceGray
        }
        guard let space = converter ?? fallback.converter else { return RgbColor(0, 0, 0) }
        do {
            try space.toRgb(padded, &rgb)
        } catch {
            return RgbColor(0, 0, 0)
        }
        return RgbColor(rgb[0], rgb[1], rgb[2])
    }
}

/// A colour set by a colour operator: its space, its numbers, and for a pattern space the pattern (a tiling pattern's
/// stream or a shading pattern's dictionary, resolved). Immutable.
public final class PdfColor {
    private var cachedRgb: RgbColor?

    public static let black = PdfColor(ColorSpaceInfo.deviceGray, [0])

    public let space: ColorSpaceInfo
    public let components: [Double]
    public let patternName: PdfName?
    public let pattern: PdfObject?

    public init(_ space: ColorSpaceInfo, _ components: [Double], _ patternName: PdfName? = nil, _ pattern: PdfObject? = nil) {
        self.space = space
        self.components = components
        self.patternName = patternName
        self.pattern = pattern
    }

    /// The colour as sRGB; for a pattern the underlying colour of an uncoloured pattern, else black.
    public var rgb: RgbColor {
        if let cachedRgb { return cachedRgb }
        let value: RgbColor
        if space.family == "Pattern" {
            if let under = space.base, components.count >= under.components {
                value = under.toRgb(components)
            } else {
                value = RgbColor(0, 0, 0)
            }
        } else {
            value = space.toRgb(components)
        }
        cachedRgb = value
        return value
    }
}

public final class GraphicsState {
    /// Maps the current user space to the space the page content started in.
    public internal(set) var ctm = PdfMatrix.identity

    /// The bounding box of the clipping path, in the space the content started in.
    public internal(set) var clip = PdfRect(0, 0, 0, 0)

    public internal(set) var fillColor = PdfColor.black
    public internal(set) var strokeColor = PdfColor.black

    public internal(set) var lineWidth = 1.0
    public internal(set) var lineCap = 0
    public internal(set) var lineJoin = 0
    public internal(set) var miterLimit = 10.0
    public internal(set) var dash: [Double] = []
    public internal(set) var dashPhase = 0.0

    public internal(set) var charSpacing = 0.0
    public internal(set) var wordSpacing = 0.0

    /// /Tz as a fraction: 1 for 100%.
    public internal(set) var horizontalScale = 1.0

    public internal(set) var leading = 0.0
    public internal(set) var font: PdfFont?
    public internal(set) var fontSize = 0.0

    /// 0 fill, 1 stroke, 2 both, 3 invisible, 4 to 7 the same and added to the clip.
    public internal(set) var renderMode = 0

    public internal(set) var rise = 0.0

    public internal(set) var fillAlpha = 1.0
    public internal(set) var strokeAlpha = 1.0
    public internal(set) var blendMode = "Normal"

    /// The /SMask of an ExtGState: a dictionary, or nil for none.
    public internal(set) var softMask: PdfDictionary?

    init() {}

    func clone() -> GraphicsState {
        let copy = GraphicsState()
        copy.ctm = ctm
        copy.clip = clip
        copy.fillColor = fillColor
        copy.strokeColor = strokeColor
        copy.lineWidth = lineWidth
        copy.lineCap = lineCap
        copy.lineJoin = lineJoin
        copy.miterLimit = miterLimit
        copy.dash = dash
        copy.dashPhase = dashPhase
        copy.charSpacing = charSpacing
        copy.wordSpacing = wordSpacing
        copy.horizontalScale = horizontalScale
        copy.leading = leading
        copy.font = font
        copy.fontSize = fontSize
        copy.renderMode = renderMode
        copy.rise = rise
        copy.fillAlpha = fillAlpha
        copy.strokeAlpha = strokeAlpha
        copy.blendMode = blendMode
        copy.softMask = softMask
        return copy
    }
}
