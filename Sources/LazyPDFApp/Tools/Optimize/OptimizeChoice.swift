import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Optimize/OptimizeChoice.cs.

public enum SizePreset: Equatable { case small, balanced, high, custom }

/// The settings behind the Custom preset.
public struct CustomSize: Equatable {
    public var imageDpi: Int
    public var jpegQuality: Int
    public var trimFonts: Bool
    public var blackWhite: Bool
    public var dropAppData: Bool
    public var dropPrivateKeys: Bool

    public init(imageDpi: Int, jpegQuality: Int, trimFonts: Bool, blackWhite: Bool, dropAppData: Bool, dropPrivateKeys: Bool) {
        self.imageDpi = imageDpi
        self.jpegQuality = jpegQuality
        self.trimFonts = trimFonts
        self.blackWhite = blackWhite
        self.dropAppData = dropAppData
        self.dropPrivateKeys = dropPrivateKeys
    }

    public static let standard = CustomSize(imageDpi: 150, jpegQuality: 75, trimFonts: true, blackWhite: true, dropAppData: true, dropPrivateKeys: false)
}

public struct OptimizeChoice: Equatable {
    public var preset: SizePreset
    public var custom: CustomSize
    public var grayscale: Bool
    public var fastWebView: Bool

    public init(_ preset: SizePreset, _ custom: CustomSize, grayscale: Bool, fastWebView: Bool) {
        self.preset = preset
        self.custom = custom
        self.grayscale = grayscale
        self.fastWebView = fastWebView
    }

    public func options(_ security: PdfSecurity?) -> OptimizeOptions {
        var options: OptimizeOptions
        switch preset {
        case .small: options = .for(.small)
        case .balanced: options = .for(.balanced)
        case .high: options = .for(.highQuality)
        case .custom:
            options = OptimizeOptions(stripPieceInfo: custom.dropAppData, stripPrivateData: custom.dropPrivateKeys,
                                      imageDpi: custom.imageDpi, imageDpiAbove: custom.imageDpi * 3 / 2, jpegQuality: custom.jpegQuality,
                                      bilevelTolerance: custom.blackWhite ? 8 : -1, subsetFonts: custom.trimFonts)
        }
        options.grayscale = grayscale
        options.security = security
        return options
    }
}
