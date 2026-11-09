import Foundation
import Observation
import LazyPDFKit

// Follows the IToolHost half of windows/LazyPDF.App/Tools/Batch/BatchWindow.xaml.cs: the Batch sheet is over the window, so it says
// what happened in the sheet itself, with its own busy bar and Cancel. Opening a file and the pickers go to the window's host.

@MainActor
@Observable
public final class BatchSheetHost: ToolHost {
    public struct Message: Equatable {
        public let title: String
        public let text: String
    }

    public private(set) var message: Message?
    public private(set) var status = ""
    public private(set) var busyText = ""
    public private(set) var isBusy = false

    @ObservationIgnored private let window: ToolHost
    @ObservationIgnored private var token: CancelToken?

    public init(window: ToolHost) {
        self.window = window
    }

    public func cancel() {
        token?.cancel()
    }

    public func runBusy(_ text: String, _ work: @MainActor (CancelToken) async throws -> Void) async throws {
        let mine = CancelToken()
        token = mine
        message = nil
        busyText = text
        isBusy = true
        defer {
            token = nil
            isBusy = false
        }
        do {
            try await work(mine)
        } catch is CancellationError {
            status = L10n.t("Cancelled.")
        }
    }

    public func setBusyText(_ text: String) { busyText = text }
    public func showProblem(_ problem: Problem) { message = Message(title: problem.title, text: problem.text) }
    public func showNotice(_ title: String, _ text: String, _ action: NoticeAction?) { message = Message(title: title, text: text) }
    public func setStatus(_ sentence: String) { status = sentence }
    public func open(_ url: URL, access: FileAccess?) async { await window.open(url, access: access) }

    public func openNew(_ pdf: [UInt8], title: String, password: String?, certificate: CertificateChoice?) async {
        await window.openNew(pdf, title: title, password: password, certificate: certificate)
    }

    public func tryReload(_ tab: DocumentTab) async -> Bool { await window.tryReload(tab) }
    public var filePicker: ToolFilePicker { window.filePicker }
    public var fileExporter: ToolFileExporter { window.fileExporter }
    public var clipboard: ToolClipboard { window.clipboard }
    public var fileWriter: FileWriter { window.fileWriter }
}
