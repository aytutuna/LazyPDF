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
            if let seed = viewer.findSeed, seed != request.text { request.text = seed }
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
        if search.hits.isEmpty { return search.isRunning ? L10n.t("Searching") : L10n.t("No results") }
        if search.isRunning { return L10n.t("{0} found", search.hits.count) }
        return L10n.t("{0} of {1}", search.current + 1, search.hits.count)
    }
}
#endif
