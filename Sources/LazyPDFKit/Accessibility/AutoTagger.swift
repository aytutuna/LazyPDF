import Foundation

// Twin of windows/LazyPDF.Core/Accessibility/AutoTagger.cs: tags an untagged document from the layout `TextPage` finds
// (ISO 32000-1 14.8, 14.7.4): headings, paragraphs, lists, tables and figures become structure elements in reading order,
// their content is wrapped in /MCID sequences, and running headers, footers, page numbers and drawing become artifacts. It
// writes /StructTreeRoot with its parent tree, /MarkInfo, /StructParents and /Tabs /S. Nothing is saved; the caller commits
// the document.
//
// The C# CancellationToken is the task's: the checks are `Task.checkCancellation()`, and `tag` throws `CancellationError`.

/// `language` is written as the document's /Lang when it has none, a BCP 47 tag such as "en-US".
public struct AutoTagOptions {
    public let language: String?

    public init(_ language: String? = nil) {
        self.language = language
    }
}

/// A figure the tagger made, for the person to give a description.
public struct TaggedFigure {
    public let pageIndex: Int
    public let reference: PdfReference

    public init(_ pageIndex: Int, _ reference: PdfReference) {
        self.pageIndex = pageIndex
        self.reference = reference
    }
}

/// `alreadyTagged`: the document had a structure tree and was left as it was. `pages`: pages that were tagged.
/// `skippedPages`: pages left without tags: shared or unreadable content streams, or more content than the interpreter runs.
/// `artifacts`: marked-content sequences written as /Artifact: paths, shadings, unclaimed images and text.
public struct AutoTagResult {
    public let alreadyTagged: Bool
    public let pages: Int
    public let skippedPages: Int
    public let headings: Int
    public let paragraphs: Int
    public let lists: Int
    public let tables: Int
    public let figures: Int
    public let artifacts: Int
    public let figuresWithoutAlt: [TaggedFigure]

    public init(_ alreadyTagged: Bool, _ pages: Int, _ skippedPages: Int, _ headings: Int, _ paragraphs: Int, _ lists: Int,
                _ tables: Int, _ figures: Int, _ artifacts: Int, _ figuresWithoutAlt: [TaggedFigure]) {
        self.alreadyTagged = alreadyTagged
        self.pages = pages
        self.skippedPages = skippedPages
        self.headings = headings
        self.paragraphs = paragraphs
        self.lists = lists
        self.tables = tables
        self.figures = figures
        self.artifacts = artifacts
        self.figuresWithoutAlt = figuresWithoutAlt
    }
}

public enum AutoTagger {
    public static func tag(_ document: PdfDocument, _ options: AutoTagOptions? = nil) throws -> AutoTagResult {
        if document.isTagged || document.dict(document.catalog, "StructTreeRoot") != nil {
            return AutoTagResult(true, 0, 0, 0, 0, 0, 0, 0, 0, [])
        }

        let interpreter = ContentInterpreter(document)
        let stats = try TagStats.collect(document, interpreter)
        let shared = TagSession.sharedStreams(document)

        var layouts: [TagPage?] = []
        for page in document.pages {
            try Task.checkCancellation()
            let text = TextPage.create(interpreter, page)
            let scan = TagScan.run(interpreter, page)
            let usable = !text.isTruncated && !scan.truncated
                && TagSession.streams(document, page).allSatisfy { shared[ObjectIdentifier($0)] == 1 }
            layouts.append(usable ? TagLayout.build(document, page, text, scan, stats) : nil)
        }

        let session = try TagSession(document, layouts)
        for i in 0..<layouts.count {
            try Task.checkCancellation()
            try session.tag(document.pages[i], layouts[i])
        }

        if session.skipped == layouts.count && !layouts.isEmpty {
            return AutoTagResult(false, 0, session.skipped, 0, 0, 0, 0, 0, 0, [])
        }
        try session.write()
        if let language = options?.language, !language.isEmpty, (PdfText.read(document, document.catalog, "Lang") ?? "").isEmpty {
            document.catalog["Lang"] = PdfText.toObject(language)
        }
        return session.result(layouts.count)
    }
}
