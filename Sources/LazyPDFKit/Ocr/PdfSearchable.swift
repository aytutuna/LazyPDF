import Foundation

// Twin of windows/LazyPDF.Core/Ocr/PdfSearchable.cs: the Make searchable action: reads the pages of a document that need
// it and adds the text layer. `IProgress<OcrProgress>` is a closure; a `CancellationToken` is the task's own
// cancellation, and a cancelled run ends with `CancellationError`. A Dpi outside 72 to 600 is thrown as
// `ArgumentException` with the .NET message, as the setting comes from the user.

/// What to do with a page that already has a layer from an earlier run.
public enum OcrExisting {
    case skip
    case replace
}

/// `language` is a BCP 47 tag, passed to the recognizer. `dpi` is the resolution pages are drawn at for the recognizer,
/// 72 to 600. `pages` are 0-based pages to look at, nil for all; out of range and repeated entries are ignored. `force`
/// reads pages with text a person can see, and pages with an invisible layer from another tool, too.
public struct OcrOptions {
    public var language: String
    public var dpi: Double
    public var existing: OcrExisting
    public var pages: [Int]?
    public var force: Bool

    public init(language: String = "en-US", dpi: Double = 300, existing: OcrExisting = .skip, pages: [Int]? = nil, force: Bool = false) {
        self.language = language
        self.dpi = dpi
        self.existing = existing
        self.pages = pages
        self.force = force
    }
}

public enum OcrOutcome {
    /// The page has a layer now.
    case added
    /// The recognizer found no words. A layer the page had under Replace is gone.
    case noWords
    /// The page was not for OCR.
    case skipped
    /// The renderer could not draw the page.
    case notRendered
}

/// `done` is the pages dealt with so far, this one included; `total` the pages the run looks at.
public struct OcrProgress: Equatable {
    public let pageIndex: Int
    public let done: Int
    public let total: Int
    public let outcome: OcrOutcome

    public init(_ pageIndex: Int, _ done: Int, _ total: Int, _ outcome: OcrOutcome) {
        self.pageIndex = pageIndex
        self.done = done
        self.total = total
        self.outcome = outcome
    }
}

public struct OcrResult: Equatable {
    public var added: Int
    public var noWords: Int
    public var skipped: Int
    public var notRendered: Int
    public var words: Int
    public var committed: Bool

    public init(_ added: Int, _ noWords: Int, _ skipped: Int, _ notRendered: Int, _ words: Int, _ committed: Bool) {
        self.added = added
        self.noWords = noWords
        self.skipped = skipped
        self.notRendered = notRendered
        self.words = words
        self.committed = committed
    }
}

/// What `PdfSearchable.readAsync` found: the counts, with no words written and nothing committed, and the words to write.
public struct OcrRead {
    public let result: OcrResult
    public let pages: [OcrPageWords]

    public init(_ result: OcrResult, _ pages: [OcrPageWords]) {
        self.result = result
        self.pages = pages
    }
}

public enum PdfSearchable {
    public static let minDpi = 72.0
    public static let maxDpi = 600.0

    /// Looks at each page (`OcrTriage`), draws the ones that need reading through `renderer`, has `recognizer` read them
    /// and writes the layers (`PdfOcrLayer.add`), then commits them as one step of the session. Nothing is changed until
    /// every page has been read, so a cancel leaves the document as it was. The renderer and the recognizer see pages in
    /// the order of the document; a failure in either is thrown as it is, with the document untouched.
    public static func runAsync(_ session: PdfEditSession, _ recognizer: TextRecognizer, _ renderer: PageRenderer,
                                _ options: OcrOptions, _ progress: ((OcrProgress) -> Void)? = nil) async throws -> OcrResult {
        let read = try await readAsync(session.document, recognizer, renderer, options, progress)
        if read.pages.isEmpty { return read.result }
        var result = read.result
        result.words = try PdfOcrLayer.add(session.document, read.pages, options.language)
        result.committed = try session.commit(OcrStatusText.label)
        return result
    }

    /// The reading half of `runAsync`, for a caller that reads a copy of the file on another thread and writes the layers
    /// into the document it shows (`PdfOcrLayer.add`). `document` is only read.
    public static func readAsync(_ document: PdfDocument, _ recognizer: TextRecognizer, _ renderer: PageRenderer,
                                 _ options: OcrOptions, _ progress: ((OcrProgress) -> Void)? = nil) async throws -> OcrRead {
        if !(options.dpi >= minDpi && options.dpi <= maxDpi) {
            throw ArgumentException("Specified argument was out of the range of valid values. (Parameter 'options')")
        }
        let count = document.pages.count
        let targets = options.pages.map { Array(Set($0.filter { $0 >= 0 && $0 < count })).sorted() } ?? Array(0..<count)

        let interpreter = ContentInterpreter(document)
        var found: [OcrPageWords] = []
        var added = 0, noWords = 0, skipped = 0, notRendered = 0, done = 0
        for index in targets {
            try Task.checkCancellation()
            let page = document.pages[index]
            let kind = OcrTriage.classify(document, page, interpreter)
            let outcome: OcrOutcome
            if !OcrTriage.needsOcr(kind, options.existing == .replace, options.force) {
                outcome = .skipped
                skipped += 1
            } else if let image = renderer.render(index, options.dpi) {
                let recognized = try await recognizer.recognizeAsync(image, options.language)
                found.append(OcrPageWords(index, recognized, image.width, image.height))
                if !OcrLayerContent.layout(recognized, image.width, image.height, PageGeometry(page)).isEmpty {
                    outcome = .added
                    added += 1
                } else {
                    outcome = .noWords
                    noWords += 1
                }
            } else {
                outcome = .notRendered
                notRendered += 1
            }
            done += 1
            progress?(OcrProgress(index, done, targets.count, outcome))
        }

        try Task.checkCancellation()
        return OcrRead(OcrResult(added, noWords, skipped, notRendered, 0, false), found)
    }
}
