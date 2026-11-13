#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/FindBar.xaml.cs: types a query into the shared ViewerSearch and steps through its hits.

struct FindBar: View {
    @Bindable var viewer: ViewerModel
    @State private var request = Request()
    @FocusState private var focused: Bool

    // What the field and the options say; a change of any starts the search again after a short pause.
    private struct Request: Hashable {
        var text = ""
        var matchCase = false
        var wholeWord = false
        var regex = false

        var options: TextSearchOptions {
            TextSearchOptions(matchCase: matchCase, wholeWord: wholeWord, regex: regex)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if let note = note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    private var note: String? {
        let search = viewer.search
        let parts = [search.capped ? L10n.t("First {0} shown. Narrow the search to see the rest.", ViewerSearch.maxHits) : nil,
                     TimedOutText.forPages(search.timedOut)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var bar: some View {
        HStack(spacing: 6) {
            TextField(L10n.t("Search text"), text: $request.text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.escape) {
                    viewer.hideFind()
                    return .handled
                }
            Text(count)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityAddTraits(.updatesFrequently)
            if viewer.search.isRunning {
                Button { viewer.search.stop() } label: { Image(systemName: "stop.circle") }
                    .accessibilityLabel(L10n.t("Stop searching"))
                    .help(L10n.t("Stop searching"))
            }
            Button { viewer.search.previous() } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(viewer.search.hits.isEmpty)
                .accessibilityLabel(L10n.t("Previous match"))
                .help(L10n.t("Previous match"))
            Button { viewer.search.next() } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(viewer.search.hits.isEmpty)
                .accessibilityLabel(L10n.t("Next match"))
                .help(L10n.t("Next match"))
            Menu {
                Toggle(L10n.t("Match case"), isOn: $request.matchCase)
                Toggle(L10n.t("Whole words"), isOn: $request.wholeWord)
                Toggle(L10n.t("Regular expression"), isOn: $request.regex)
            } label: {
                Image(systemName: "textformat")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.t("Search the file"))
            Button { viewer.hideFind() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(L10n.t("Close the search bar"))
                .help(L10n.t("Close the search bar"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .task(id: request) { await search() }
        .onChange(of: viewer.findRequest, initial: true) {
            if let seed = viewer.findSeed {
                if seed != request.text { request.text = seed }
            } else if !viewer.search.query.isEmpty {
                let running = viewer.search
                request = Request(text: running.query, matchCase: running.options.matchCase,
                                  wholeWord: running.options.wholeWord, regex: running.options.regex)
            } else if request.text.isEmpty, let last = viewer.lastFind {
                request = Request(text: last.text, matchCase: last.options.matchCase,
                                  wholeWord: last.options.wholeWord, regex: last.options.regex)
            }
            focused = true
        }
    }

    // A typed query waits a moment for the next key; an option applies at once.
    private func search() async {
        let search = viewer.search
        let same = search.query == request.text && search.options.matchCase == request.matchCase
            && search.options.wholeWord == request.wholeWord && search.options.regex == request.regex
        if same { return }
        if !request.text.isEmpty && request.text != search.query {
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
        }
        search.start(request.text, request.options)
    }

    // Return goes to the next hit; while the typed query has not been searched yet it searches it first.
    private func submit() {
        let search = viewer.search
        if search.query != request.text {
            search.start(request.text, request.options)
        } else {
            search.next()
        }
    }

    private var count: String {
        let search = viewer.search
        if search.query.isEmpty { return "" }
        if search.badPattern { return L10n.t("Not a valid pattern") }
        if search.stopped { return search.hits.isEmpty ? L10n.t("Stopped") : L10n.t("{0} found, stopped", search.hits.count) }
        if search.hits.isEmpty {
            return search.isRunning ? L10n.t("Searching")
                : !search.timedOut.isEmpty ? L10n.t("Not fully searched")
                : search.noText ? L10n.t("This file has no text to search. Try Make searchable.") : L10n.t("No results")
        }
        if search.isRunning { return L10n.t("{0} found", search.hits.count) }
        if search.wrapped == .start { return L10n.t("{0} of {1}, from the start", search.current + 1, search.hits.count) }
        if search.wrapped == .end { return L10n.t("{0} of {1}, from the end", search.current + 1, search.hits.count) }
        return L10n.t("{0} of {1}", search.current + 1, search.hits.count)
    }
}
#endif
