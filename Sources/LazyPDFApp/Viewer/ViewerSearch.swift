import Foundation
import Observation
import LazyPDFKit

// Port of windows/LazyPDF.App/Viewer/ViewerSearch.cs.

/// A match and the words around it, for the list in the Search panel.
public struct SearchHit {
    public let match: SearchMatch
    public let before: String
    public let after: String

    public var page: Int { match.page }

    public var text: String { match.text }

    public var pageText: String { L10n.t("Page {0}", page + 1) }

    /// What a screen reader says for the row: the page, then the words around the match.
    public var spoken: String { "\(pageText). \(before)\(text)\(after)" }
}

/// One search of the open file, shared by the find bar, the highlights on the pages and the Search panel. It runs off the
/// main actor and delivers hits in batches; starting another search cancels the one running.
@MainActor
@Observable
public final class ViewerSearch {
    private nonisolated static let context = 32
    private nonisolated static let batch = 25

    @ObservationIgnored private let source: () -> Task<TextSource?, Never>
    @ObservationIgnored private let startPage: () -> Int
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var quiet = false

    public private(set) var hits: [SearchHit] = []

    public private(set) var query = ""

    public private(set) var options = TextSearchOptions()

    /// The hit the viewer is at, or -1.
    public private(set) var current = -1

    public private(set) var isRunning = false

    /// The query is a regular expression that does not parse.
    public private(set) var badPattern = false

    /// Called when `current` moved, so the view goes to it.
    @ObservationIgnored public var onCurrentChanged: (() -> Void)?

    /// `source` gives the text of the file, nil when it cannot be read; `startPage` the page the first current hit is taken from.
    public init(source: @escaping () -> Task<TextSource?, Never>, startPage: @escaping () -> Int) {
        self.source = source
        self.startPage = startPage
    }

    /// Searches for `query`; an empty one clears. The task ends when the search has.
    @discardableResult
    public func start(_ query: String, _ options: TextSearchOptions) -> Task<Void, Never> {
        quiet = false
        running?.cancel()
        generation += 1
        let id = generation
        hits = []
        current = -1
        self.query = query
        self.options = options
        badPattern = false
        if query.isEmpty {
            isRunning = false
            return Task {}
        }
        isRunning = true
        let first = startPage()
        let text = source()
        let task = Task { await self.run(text, query, options, first, id) }
        running = task
        return task
    }

    public func clear() {
        start("", options)
    }

    /// Searches again for the same query after the file changed. The view stays where it is: only the user's own moves go to a hit.
    @discardableResult
    public func restart() -> Task<Void, Never> {
        let task = start(query, options)
        quiet = true
        return task
    }

    public func next() {
        move(1)
    }

    public func previous() {
        move(-1)
    }

    private func move(_ step: Int) {
        if hits.isEmpty { return }
        quiet = false
        select(((current < 0 ? (step > 0 ? -1 : 0) : current) + step + hits.count) % hits.count)
    }

    public func select(_ index: Int) {
        guard index >= 0 && index < hits.count else { return }
        quiet = false
        current = index
        onCurrentChanged?()
    }

    private nonisolated func run(_ text: Task<TextSource?, Never>, _ query: String, _ options: TextSearchOptions, _ start: Int, _ id: Int) async {
        var bad = false
        do {
            if let source = await text.value {
                var batch: [SearchHit] = []
                for try await match in try source.find(query, options) {
                    batch.append(SearchHit(match: match, before: Self.around(source, match, -1), after: Self.around(source, match, 1)))
                    if batch.count >= Self.batch {
                        await deliver(batch, start, id)
                        batch = []
                    }
                }
                await deliver(batch, start, id)
            }
        } catch is CancellationError {
            return
        } catch {
            bad = true
        }
        await finish(bad, id)
    }

    private func deliver(_ batch: [SearchHit], _ start: Int, _ id: Int) {
        guard id == generation, !batch.isEmpty else { return }
        let first = current < 0
        for hit in batch {
            hits.append(hit)
            if current < 0 && hit.page >= start { current = hits.count - 1 }
        }
        if first && current >= 0 && !quiet { onCurrentChanged?() }
    }

    private func finish(_ bad: Bool, _ id: Int) {
        guard id == generation else { return }
        isRunning = false
        badPattern = bad
        if current < 0 && !hits.isEmpty {
            current = 0
            if !quiet { onCurrentChanged?() }
        }
    }

    private nonisolated static func around(_ source: TextSource, _ match: SearchMatch, _ side: Int) -> String {
        let page = source.page(match.page)
        let length = page.chars.count
        let range = side < 0
            ? TextRange(Swift.max(0, match.range.start - context), match.range.start)
            : TextRange(match.range.end, Swift.min(length, match.range.end + context))
        return range.isEmpty ? "" : page.getText(range).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }
}
