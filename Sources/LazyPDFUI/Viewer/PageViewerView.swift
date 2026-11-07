#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Viewer/PageViewer.xaml: the page viewer in the stage, a bar with page, zoom and view controls over
// the scrolling pages, a find bar, and the question before an address is opened. The pages are the platform's scroll view.

public struct PageViewerView: View {
    @Bindable var viewer: ViewerModel

    public init(viewer: ViewerModel) {
        self.viewer = viewer
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !viewer.readingMode {
                ViewerBar(viewer: viewer)
                if viewer.findVisible { FindBar(viewer: viewer) }
            }
            ZStack {
                PageScrollRepresentable(viewer: viewer)
                if viewer.cannotDraw {
                    Text(L10n.t("This file's pages cannot be shown here. You can still edit and save it."))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                        .padding()
                }
                VStack(spacing: 8) {
                    if viewer.readingMode {
                        HStack {
                            Spacer()
                            Button(L10n.t("Exit reading mode")) { viewer.readingMode = false }
                                .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    Spacer()
                    if let pending = viewer.pendingAddress { linkCard(pending) }
                    if viewer.placement != nil { cue }
                }
                .padding(.bottom, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Page viewer"))
    }

    private func linkCard(_ pending: PendingAddress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pending.openable ? L10n.t("Open this link?") : L10n.t("This link cannot be opened.")).font(.headline)
            Text(pending.address).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                Button(pending.openable ? L10n.t("Cancel") : L10n.t("Close")) { viewer.dismissPendingAddress() }
                    .keyboardShortcut(.cancelAction)
                if pending.openable {
                    Button(L10n.t("Open")) { viewer.openPendingAddress() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Open this link?"))
    }

    private var cue: some View {
        Text(L10n.t("Arrow keys move it. Enter places it. Escape cancels."))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
#endif
