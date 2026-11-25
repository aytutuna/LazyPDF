#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The view of CompareWindowModel; follows windows/LazyPDF.App/Tools/Compare/CompareWindow.xaml. The list of differences, and
// the two files side by side (one above the other on a narrow screen) or the new one with what differs painted over it.

struct CompareSheetView: View {
    @Bindable var window: CompareWindowModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    overlayPicker.frame(maxWidth: 260)
                    linkToggle
                    Spacer()
                    doneButton
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        overlayPicker.frame(maxWidth: .infinity)
                        doneButton
                    }
                    linkToggle
                }
            }
            .padding(12)
            Divider()
            GeometryReader { proxy in
                if proxy.size.width >= 700 { wide } else { narrow }
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(window.title)
    }

    private var overlayPicker: some View {
        Picker(L10n.t("Side by side"), selection: Binding(get: { window.overlayMode }, set: { window.setOverlay($0) })) {
            Text(L10n.t("Side by side")).tag(false)
            Text(L10n.t("Overlay")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var linkToggle: some View {
        Toggle(L10n.t("Scroll together"), isOn: Binding(get: { window.linked }, set: { window.setLinked($0) }))
            .disabled(window.overlayMode)
    }

    private var doneButton: some View {
        Button(L10n.t("Done"), action: close)
            .keyboardShortcut(.cancelAction)
    }

    private var wide: some View {
        HStack(spacing: 0) {
            list.frame(width: 240)
            Divider()
            if !window.overlayMode {
                pane(window.oldTitle, window.oldViewer)
                Divider()
            }
            pane(window.newTitle, window.newViewer)
        }
    }

    private var narrow: some View {
        VStack(spacing: 0) {
            list.frame(height: 150)
            Divider()
            if !window.overlayMode {
                pane(window.oldTitle, window.oldViewer)
                Divider()
            }
            pane(window.newTitle, window.newViewer)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ChangeListView(rows: window.rows) { window.go($0) }
            Text(window.legend)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    private func pane(_ title: String, _ viewer: ViewerModel) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            PageViewerView(viewer: viewer)
        }
    }
}
#endif
