import Foundation

// Twin of windows/LazyPDF.Core/Optimize/OptimizeTypes.cs: the options, plans and results of the optimizer and the
// sanitizer. The C# records with init properties are structs with a defaulted initialiser.

public enum OptimizePreset { case small, balanced, highQuality }

public enum OptimizeStepKind {
    case removeUnreferenced
    case objectStreams
    case recompressStreams
    case convertOldFilters
    case removeDuplicates
    case stripThumbnails
    case stripPieceInfo
    case stripPrivateData
    case pruneResources
    case downsampleImages
    case bilevelImages
    case subsetFonts
    case grayscale
}

/// What the optimizer does. `for` gives the three presets.
public struct OptimizeOptions {
    public var objectStreams = true
    public var recompressStreams = true
    public var convertOldFilters = true
    public var removeDuplicates = true
    public var stripThumbnails = true
    public var stripPieceInfo = true
    public var stripPrivateData = false
    public var pruneResources = true

    /// The resolution images are brought down to; 0 leaves images alone.
    public var imageDpi = 0

    /// Only images placed at more than this many dpi are touched.
    public var imageDpiAbove = 0

    /// Quality (1 to 100) of JPEG data written when an image is downsampled or turned gray.
    public var jpegQuality = 75

    /// Gray and colour images whose pixels are all within this many levels of black or white become 1-bit; negative leaves them.
    public var bilevelTolerance = -1

    public var subsetFonts = false
    public var grayscale = false

    /// Encrypts the new file; nil writes it open, whatever the source was.
    public var security: PdfSecurity?

    /// First string of the new /ID, as in `PdfSaveOptions`.
    public var documentId: [UInt8]?

    public init(objectStreams: Bool = true, recompressStreams: Bool = true, convertOldFilters: Bool = true, removeDuplicates: Bool = true,
                stripThumbnails: Bool = true, stripPieceInfo: Bool = true, stripPrivateData: Bool = false, pruneResources: Bool = true,
                imageDpi: Int = 0, imageDpiAbove: Int = 0, jpegQuality: Int = 75, bilevelTolerance: Int = -1, subsetFonts: Bool = false,
                grayscale: Bool = false, security: PdfSecurity? = nil, documentId: [UInt8]? = nil) {
        self.objectStreams = objectStreams
        self.recompressStreams = recompressStreams
        self.convertOldFilters = convertOldFilters
        self.removeDuplicates = removeDuplicates
        self.stripThumbnails = stripThumbnails
        self.stripPieceInfo = stripPieceInfo
        self.stripPrivateData = stripPrivateData
        self.pruneResources = pruneResources
        self.imageDpi = imageDpi
        self.imageDpiAbove = imageDpiAbove
        self.jpegQuality = jpegQuality
        self.bilevelTolerance = bilevelTolerance
        self.subsetFonts = subsetFonts
        self.grayscale = grayscale
        self.security = security
        self.documentId = documentId
    }

    public static func `for`(_ preset: OptimizePreset) -> OptimizeOptions {
        switch preset {
        case .small:
            return OptimizeOptions(stripPrivateData: true, imageDpi: 96, imageDpiAbove: 144, jpegQuality: 50, bilevelTolerance: 24, subsetFonts: true)
        case .balanced:
            return OptimizeOptions(imageDpi: 150, imageDpiAbove: 225, jpegQuality: 80, subsetFonts: true)
        case .highQuality:
            return OptimizeOptions(stripPieceInfo: false, imageDpi: 300, imageDpiAbove: 450, jpegQuality: 92, bilevelTolerance: 0)
        }
    }
}

public enum SpaceKind: Int, CaseIterable, Hashable {
    case images, fonts, content, forms, annotations, metadata, structure, attachments, overhead, unreferenced
}

/// Where the bytes of a file go. The kinds add up to `fileSize`.
public struct SpaceAudit {
    public let fileSize: Int
    public let bytes: [SpaceKind: Int]

    public init(_ fileSize: Int, _ bytes: [SpaceKind: Int]) {
        self.fileSize = fileSize
        self.bytes = bytes
    }

    public func of(_ kind: SpaceKind) -> Int { bytes[kind] ?? 0 }
}

/// The audit and the steps the options would run; the counts come with the run.
public struct OptimizePlan {
    public let audit: SpaceAudit
    public let steps: [OptimizeStepKind]
}

/// How many things a step changed.
public struct OptimizeStepResult: Equatable {
    public let kind: OptimizeStepKind
    public let count: Int

    public init(_ kind: OptimizeStepKind, _ count: Int) {
        self.kind = kind
        self.count = count
    }
}

public struct OptimizeResult {
    public let bytes: [UInt8]
    public let sizeBefore: Int
    public let sizeAfter: Int
    public let audit: SpaceAudit
    public let steps: [OptimizeStepResult]
    public let notes: [String]
    public var dropped = 0
}

public enum SanitizeItem: Int, CaseIterable, Hashable {
    case javaScript
    case launchActions
    case embeddedFiles
    case hiddenLayers
    case hiddenText
    case invisibleText
    case comments
    case formData
    case metadata
    case pieceInfo
    case thumbnails
    case previousVersions
    case searchIndexes
    case externalLinks
    case filePaths
    case signatures
}

public struct SanitizeFinding: Equatable {
    public let item: SanitizeItem
    public let count: Int

    public init(_ item: SanitizeItem, _ count: Int) {
        self.item = item
        self.count = count
    }
}

/// What the sanitizer removes. Text in render mode 3 may be an OCR layer, so it goes only when asked.
public struct SanitizeOptions {
    public var javaScript = true
    public var launchActions = true
    public var embeddedFiles = true
    public var hiddenLayers = true
    public var invisibleText = false
    public var comments = true
    public var formData = true
    public var metadata = true
    public var pieceInfo = true
    public var thumbnails = true
    public var searchIndexes = true
    public var externalLinks = true
    public var filePaths = true

    /// Write the output with the input's encryption; ignored when `security` is given.
    public var keepEncryption = true

    public var security: PdfSecurity?
    public var documentId: [UInt8]?

    public init(javaScript: Bool = true, launchActions: Bool = true, embeddedFiles: Bool = true, hiddenLayers: Bool = true,
                invisibleText: Bool = false, comments: Bool = true, formData: Bool = true, metadata: Bool = true, pieceInfo: Bool = true,
                thumbnails: Bool = true, searchIndexes: Bool = true, externalLinks: Bool = true, filePaths: Bool = true,
                keepEncryption: Bool = true, security: PdfSecurity? = nil, documentId: [UInt8]? = nil) {
        self.javaScript = javaScript
        self.launchActions = launchActions
        self.embeddedFiles = embeddedFiles
        self.hiddenLayers = hiddenLayers
        self.invisibleText = invisibleText
        self.comments = comments
        self.formData = formData
        self.metadata = metadata
        self.pieceInfo = pieceInfo
        self.thumbnails = thumbnails
        self.searchIndexes = searchIndexes
        self.externalLinks = externalLinks
        self.filePaths = filePaths
        self.keepEncryption = keepEncryption
        self.security = security
        self.documentId = documentId
    }
}

/// `removed` are the findings taken out, `kept` what was found and left (an item switched off, or hidden text, which is only reported).
public struct SanitizeResult {
    public let bytes: [UInt8]
    public let removed: [SanitizeFinding]
    public let kept: [SanitizeFinding]
    public let sizeBefore: Int
    public let sizeAfter: Int
}
