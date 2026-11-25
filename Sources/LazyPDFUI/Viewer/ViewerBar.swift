#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows the bar of windows/LazyPDF.App/Viewer/PageViewer.xaml: back and forward, the page, the zoom, Find, the pointer mode
// and the view options. A narrow bar leaves out what the View menu also has, as the Windows bar does below 470 and 400.

struct ViewerBar: View {
    @Bindable var viewer: ViewerModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    private static let presets = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 4]

    var body: some View {
        let narrow = sizeClass == .compact
        HStack(spacing: 4) {
            if !narrow {
                button("arrow.backward", L10n.t("Back"), enabled: viewer.canGoBack) { viewer.goBack() }
                button("arrow.forward", L10n.t("Forward"), enabled: viewer.canGoForward) { viewer.goForward() }
                Divider().frame(height: 18)
            }
            button("chevron.up", L10n.t("Previous page"), enabled: viewer.pageIndex > 0) { viewer.stepPage(-1) }
            Button { viewer.showGoToPage() } label: {
                Text("\(viewer.pageLabel(viewer.pageIndex)) \(L10n.t("of {0}", viewer.pageCount))").monospacedDigit()
            }
            .accessibilityLabel(L10n.t("Go to page"))
            .popover(isPresented: $viewer.goToPageVisible) { GoToPageView(viewer: viewer) }
            button("chevron.down", L10n.t("Next page"), enabled: viewer.pageIndex < viewer.pageCount - 1) { viewer.stepPage(1) }
            Spacer(minLength: 8)
            if !narrow { button("minus", L10n.t("Zoom out"), enabled: true) { viewer.zoomOut() } }
            zoomMenu
            if !narrow { button("plus", L10n.t("Zoom in"), enabled: true) { viewer.zoomIn() } }
            Divider().frame(height: 18)
            button("magnifyingglass", L10n.t("Search"), enabled: true) { viewer.showFind() }
            if !narrow {
                Toggle(isOn: modeBinding(.select)) { Image(systemName: "text.cursor") }
                    .toggleStyle(.button)
                    .accessibilityLabel(L10n.t("Select text"))
                Toggle(isOn: modeBinding(.hand)) { Image(systemName: "hand.raised") }
                    .toggleStyle(.button)
                    .accessibilityLabel(L10n.t("Hand tool"))
            }
            viewMenu(narrow: narrow)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
        .disabled(viewer.tab == nil)
    }

    private func button(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .disabled(!enabled)
            .accessibilityLabel(label)
            .help(label)
    }

    private func modeBinding(_ mode: PointerMode) -> Binding<Bool> {
        Binding(get: { viewer.mode == mode && viewer.pointerTool == nil }, set: { if $0 { viewer.mode = mode } })
    }

    private var zoomText: String {
        viewer.tab == nil ? "" : L10n.t("{0} %", Int((viewer.zoom * 100).rounded()))
    }

    private var zoomMenu: some View {
        Menu {
            Button(L10n.t("Fit width")) { viewer.fitWidth() }
            Button(L10n.t("Fit page")) { viewer.fitPage() }
            Button(L10n.t("Actual size")) { viewer.actualSize() }
            Divider()
            ForEach(Self.presets, id: \.self) { preset in
                Button(L10n.t("{0} %", Int(preset * 100))) { viewer.zoom = preset }
            }
        } label: {
            Text(zoomText).monospacedDigit()
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.t("Zoom"))
        .accessibilityValue(zoomText)
    }

    private func viewMenu(narrow: Bool) -> some View {
        Menu {
            if narrow {
                Section {
                    Toggle(L10n.t("Select text"), isOn: modeBinding(.select))
                    Toggle(L10n.t("Hand tool"), isOn: modeBinding(.hand))
                }
                Section {
                    Button(L10n.t("Back")) { viewer.goBack() }.disabled(!viewer.canGoBack)
                    Button(L10n.t("Forward")) { viewer.goForward() }.disabled(!viewer.canGoForward)
                }
            }
            Section {
                Toggle(L10n.t("One page"), isOn: Binding(get: { viewer.columns == 1 },
                                                       set: { if $0 { viewer.columns = 1 } }))
                Toggle(L10n.t("Scroll continuously"), isOn: $viewer.continuous)
                Toggle(L10n.t("Two pages"), isOn: Binding(get: { viewer.columns == 2 }, set: { viewer.columns = $0 ? 2 : 1 }))
                Toggle(L10n.t("Show cover page"), isOn: $viewer.coverPage).disabled(viewer.columns != 2)
            }
            Section {
                Button(L10n.t("Rotate clockwise")) { viewer.rotation += 90 }
                Button(L10n.t("Rotate counterclockwise")) { viewer.rotation -= 90 }
            }
            Section {
                Picker(L10n.t("Pages"), selection: $viewer.tint) {
                    Text(L10n.t("Light pages")).tag(PageTint.none)
                    Text(L10n.t("Dark pages")).tag(PageTint.dark)
                    Text(L10n.t("Sepia pages")).tag(PageTint.sepia)
                }
            }
            Toggle(L10n.t("Reading mode"), isOn: $viewer.readingMode)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.t("View options"))
    }
}

struct GoToPageView: View {
    @Bindable var viewer: ViewerModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Go to page")).font(.headline)
            HStack {
                TextField(L10n.t("Page"), text: $text)
                    .focused($focused)
                    .onSubmit(go)
                    .frame(minWidth: 80)
                Text(L10n.t("of {0}", viewer.pageCount)).foregroundStyle(.secondary)
                Button(L10n.t("Go"), action: go).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear {
            text = viewer.pageLabel(viewer.pageIndex)
            focused = true
        }
    }

    private func go() {
        if viewer.goToPage(typed: text) { viewer.goToPageVisible = false }
    }
}
#endif
