#if canImport(SwiftUI)
import SwiftUI
import LazyPDFApp
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Batch/BatchWindow.xaml: runs a batch from the Home tab, where no document is open for the
// panel to sit beside. It says what happened in the sheet itself.

enum AppleBatch {
    static func runner() -> BatchRunner {
        BatchRunner(codec: ImageIOCodec(), fonts: CoreTextFontSource(), recognizer: VisionTextRecognizer(), renderers: { PdfKitRenderer() })
    }

    static var watcher: FolderWatchFactory? {
        #if os(macOS)
        return FolderWatcher.factory
        #else
        return nil
        #endif
    }
}

public struct BatchSheet: View {
    @State private var model: BatchModel
    let close: () -> Void

    public init(host: AppViewModel, folders: AppFolders, close: @escaping () -> Void) {
        _model = State(initialValue: BatchModel.sheet(window: host, settings: folders.settings, watcher: AppleBatch.watcher, runner: AppleBatch.runner))
        self.close = close
    }

    init(model: BatchModel, close: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.close = close
    }

    public var body: some View {
        let host = model.sheetHost
        VStack(spacing: 0) {
            Text(L10n.t("Batch"))
                .font(.headline)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            ScrollView { BatchPanelView(model: model) }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if let message = host?.message {
                    Text(message.title).fontWeight(.semibold)
                    Text(message.text)
                }
                if let status = host?.status, !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
                }
                if host?.isBusy == true {
                    ProgressView().progressViewStyle(.linear).accessibilityLabel(host?.busyText ?? "")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            HStack {
                Spacer()
                if host?.isBusy == true { Button(L10n.t("Cancel")) { host?.cancel() } }
                Button(L10n.t("Close"), role: .cancel) { finish() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Run on every file")) { Task { await model.run() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRun || host?.isBusy == true)
            }
            .padding(12)
        }
        .onDisappear { model.stopWatching() }
        #if os(macOS)
        .frame(width: 440, height: 640)
        #endif
    }

    private func finish() {
        model.sheetHost?.cancel()
        model.stopWatching()
        close()
    }
}
#endif
