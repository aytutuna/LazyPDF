#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The info bar over the window and the status line under it (MainWindow.xaml: InfoBar and the StatusBar).

struct InfoBar: View {
    let vm: AppViewModel
    // A sheet over the window repeats the bar; only one of them speaks.
    var announces = true

    var body: some View {
        if let message = vm.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: message.isError ? "exclamationmark.octagon.fill" : "info.circle.fill")
                    .foregroundStyle(message.isError ? Color.red : Color.orange)
                    .accessibilityHidden(true)
                (Text(message.title).fontWeight(.semibold) + Text("  ") + Text(message.text))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(message.title). \(message.text)")
                if let action = message.action {
                    Button(action.text) {
                        vm.dismissMessage()
                        action.run()
                    }
                    .disabled(vm.isBusy)
                }
                Button {
                    vm.dismissMessage()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(L10n.t("Dismiss"))
                .accessibilityLabel(L10n.t("Dismiss"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((message.isError ? Color.red : Color.orange).opacity(0.15))
            .onChange(of: "\(message.title). \(message.text)", initial: true) { _, spoken in
                if announces { AccessibilityNotification.Announcement(spoken).post() }
            }
        }
    }
}

struct StatusBar: View {
    let vm: AppViewModel
    var announces = true

    var body: some View {
        let spoken = vm.isBusy ? vm.busyText : vm.statusFull
        HStack(spacing: 12) {
            Text(vm.isBusy ? vm.busyText : vm.statusShort)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(spoken)
                .accessibilityLabel(spoken)
            Spacer(minLength: 12)
            if let tab = vm.activeDocument {
                let page = pageText(tab)
                let zoom = zoomText(tab)
                Text(page).font(.callout).fixedSize()
                Text(zoom).font(.callout).fixedSize().accessibilityLabel("\(L10n.t("Zoom")) \(zoom)")
            }
            if vm.isBusy {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                    .accessibilityLabel(L10n.t("Progress"))
                Button {
                    vm.cancelBusy()
                } label: {
                    Label(L10n.t("Cancel"), systemImage: "xmark")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: spoken) { _, text in
            if announces && !text.isEmpty { AccessibilityNotification.Announcement(text).post() }
        }
    }

    // Reading the revision makes the line follow the tab when its bytes change.
    private func pageText(_ tab: DocumentTab) -> String {
        _ = tab.revision
        let count = tab.pageCount
        let index = min(max(tab.pageIndex, 0), max(0, count - 1))
        return L10n.t("Page {0} of {1}", index + 1, count)
    }

    private func zoomText(_ tab: DocumentTab) -> String {
        tab.zoom > 0 ? L10n.t("{0} %", Int((tab.zoom * 100).rounded())) : L10n.t("Fit")
    }
}
#endif
