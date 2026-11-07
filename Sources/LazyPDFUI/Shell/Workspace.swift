#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// The rail, the side pane and the inspector of MainWindow.xaml, and the file facts the inspector shows with no tool open
// (MainWindow.Tools.cs: DocumentSummary).

struct Rail: View {
    let vm: AppViewModel
    /// nil collapses or brings back the pane.
    let choose: (String?) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button {
                choose(nil)
            } label: {
                Image(systemName: "sidebar.left").frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.t("Show or hide the side panel"))
            .accessibilityLabel(L10n.t("Show or hide the side panel"))
            ForEach(ToolCatalog.sidePanels, id: \.id) { panel in
                let on = vm.sidePanelId == panel.id
                Button {
                    choose(panel.id)
                } label: {
                    Image(systemName: panel.symbol)
                        .frame(width: 32, height: 28)
                        .background(on ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(panel.title)
                .accessibilityLabel(panel.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(width: 48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Side panels"))
    }
}

struct PaneFrame<Content: View>: View {
    let symbol: String?
    let title: String
    let closeHelp: String?
    let close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(Color.accentColor)
                }
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let closeHelp {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(closeHelp)
                    .accessibilityLabel(closeHelp)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            content()
        }
    }
}

/// The accent button pinned under a tool's panel.
struct ActionFooter: View {
    let action: ToolAction
    let running: Bool
    let run: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: run) {
                Label(action.text, systemImage: action.symbol).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(running || !action.canRun())
            .help(action.hint ?? "")
            .accessibilityHint(action.hint ?? "")
            .padding(12)
        }
    }
}

struct DocumentSummary: View {
    let tab: DocumentTab

    var body: some View {
        let _ = tab.revision
        let document = tab.document
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                row(L10n.t("File"), tab.title)
                if let url = tab.url {
                    row(L10n.t("Folder"), url.deletingLastPathComponent().path)
                }
                row(L10n.t("Pages"), String(tab.pageCount))
                row(L10n.t("PDF version"), document.version)
                row(L10n.t("Size"), Self.size(tab.session.current.count))
                row(L10n.t("Protection"), !document.isEncrypted ? L10n.t("Not protected")
                    : document.security?.isPublicKey == true ? L10n.t("Protected for certificate holders") : L10n.t("Password protected"))
                if document.isSigned {
                    row(L10n.t("Signatures"), document.isCertified ? L10n.t("Signed and certified") : L10n.t("Signed"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    static func size(_ bytes: Int) -> String {
        func rounded(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) }
        if bytes < 1024 { return L10n.t("{0} bytes", bytes) }
        if bytes < 1024 * 1024 { return L10n.t("{0} KB", rounded(Double(bytes) / 1024)) }
        return L10n.t("{0} MB", rounded(Double(bytes) / 1_048_576))
    }
}
#endif
