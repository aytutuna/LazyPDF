import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Batch/BatchModel.cs: the steps of a batch, the named sets of steps and the file the sets
// are kept in. The engine's enums are not Codable, so the settings that name one are kept as their own cases.

public enum BatchStepKind: Int, CaseIterable, Codable {
    case ocr, compress, clean, watermark, bates, pdfA
}

public enum BatesPlace: Int, CaseIterable, Codable {
    case footerRight, footerCenter, footerLeft, headerRight, headerCenter, headerLeft
}

public enum BatchPreset: Int, CaseIterable, Codable {
    case small, balanced, highQuality

    var preset: OptimizePreset {
        switch self {
        case .small: return .small
        case .balanced: return .balanced
        case .highQuality: return .highQuality
        }
    }
}

public enum BatchLevel: Int, CaseIterable, Codable {
    case a1b, a2b, a2u, a3b, a3u, a4

    var level: PdfALevel {
        switch self {
        case .a1b: return .a1b
        case .a2b: return .a2b
        case .a2u: return .a2u
        case .a3b: return .a3b
        case .a3u: return .a3u
        case .a4: return .a4
        }
    }
}

/// One step and the settings it uses; the settings of the other kinds are left alone.
public struct BatchStep: Codable, Equatable {
    public var kind: BatchStepKind

    /// The language tag of Ocr, the text of Watermark, the prefix of Bates.
    public var text = ""
    public var preset = BatchPreset.balanced
    public var level = BatchLevel.a2b
    public var digits = 6

    /// The number the next file starts at; a run moves it on, so the numbers go on from one file to the next.
    public var start = 1
    public var suffix = ""
    public var place = BatesPlace.footerRight
    public var opacity = 30

    /// Degrees counter-clockwise.
    public var angle = 0

    /// The width of the watermark as a percentage of the page.
    public var size = 60
    public var anchorIndex = StampAnchor.center.rawValue
    public var keepComments = false
    public var keepForms = false
    public var keepLinks = false
    public var keepAttachments = false

    public init(_ kind: BatchStepKind) {
        self.kind = kind
    }

    public var anchor: StampAnchor {
        get { StampAnchor(rawValue: anchorIndex) ?? .center }
        set { anchorIndex = newValue.rawValue }
    }

    public static func of(_ kind: BatchStepKind) -> BatchStep {
        var step = BatchStep(kind)
        if kind == .ocr { step.text = OcrLanguageState.read().preferred()?.tag ?? "en-US" }
        return step
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, preset, level, digits, start, suffix, place, opacity, angle, size, anchorIndex
        case keepComments, keepForms, keepLinks, keepAttachments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(BatchStepKind.self, forKey: .kind)
        text = c.decodeLenient(forKey: .text, default: text)
        preset = c.decodeLenient(forKey: .preset, default: preset)
        level = c.decodeLenient(forKey: .level, default: level)
        digits = c.decodeLenient(forKey: .digits, default: digits)
        start = c.decodeLenient(forKey: .start, default: start)
        suffix = c.decodeLenient(forKey: .suffix, default: suffix)
        place = c.decodeLenient(forKey: .place, default: place)
        opacity = c.decodeLenient(forKey: .opacity, default: opacity)
        angle = c.decodeLenient(forKey: .angle, default: angle)
        size = c.decodeLenient(forKey: .size, default: size)
        anchorIndex = c.decodeLenient(forKey: .anchorIndex, default: anchorIndex)
        keepComments = c.decodeLenient(forKey: .keepComments, default: keepComments)
        keepForms = c.decodeLenient(forKey: .keepForms, default: keepForms)
        keepLinks = c.decodeLenient(forKey: .keepLinks, default: keepLinks)
        keepAttachments = c.decodeLenient(forKey: .keepAttachments, default: keepAttachments)
    }
}

/// A named list of steps with where the results go and what to call them. The folders are paths for the person to read; the
/// bookmarks are what gives the sandboxed app its access to them again.
public struct BatchSet: Codable, Equatable {
    public var name = ""
    public var steps: [BatchStep] = []
    public var outputFolder = ""
    public var outputBookmark: Data?

    /// The file name of a result: {name}, {n} for the place in the run and {date} or {date:format}.
    public var nameTemplate = "{name}"
    public var watchFolder = ""
    public var watchBookmark: Data?

    public init(name: String = "", steps: [BatchStep] = [], outputFolder: String = "", nameTemplate: String = "{name}", watchFolder: String = "") {
        self.name = name
        self.steps = steps
        self.outputFolder = outputFolder
        self.nameTemplate = nameTemplate
        self.watchFolder = watchFolder
    }

    private enum CodingKeys: String, CodingKey {
        case name, steps, outputFolder, outputBookmark, nameTemplate, watchFolder, watchBookmark
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.decodeLenient(forKey: .name, default: name)
        steps = c.decodeLenient(forKey: .steps, default: steps)
        outputFolder = c.decodeLenient(forKey: .outputFolder, default: outputFolder)
        outputBookmark = c.decodeLenient(forKey: .outputBookmark, default: outputBookmark)
        nameTemplate = c.decodeLenient(forKey: .nameTemplate, default: nameTemplate)
        watchFolder = c.decodeLenient(forKey: .watchFolder, default: watchFolder)
        watchBookmark = c.decodeLenient(forKey: .watchBookmark, default: watchBookmark)
    }
}

struct BatchSets: Codable {
    var sets: [BatchSet] = []
}

/// batch-sets.json in the settings folder: the sets the person saved.
struct BatchSetStore {
    private let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("batch-sets.json")
    }

    func load() -> [BatchSet] {
        (StoreFiles.load(BatchSets.self, from: url)?.sets ?? []).filter { !$0.name.isEmpty }
    }

    func save(_ set: BatchSet) {
        var sets = load().filter { $0.name.caseInsensitiveCompare(set.name) != .orderedSame }
        sets.append(set)
        StoreFiles.write(BatchSets(sets: sets), to: url)
    }

    func delete(_ name: String) {
        StoreFiles.write(BatchSets(sets: load().filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }), to: url)
    }
}
