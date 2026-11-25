import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Comment/CommentPanel.Exchange.cs: comments to and from FDF and XFDF files, flattening,
// and attaching a file. Files come from host.filePicker and go through host.fileExporter, since a sandboxed app reads only
// what the person chose.

extension CommentModel {
    static let maxAttachment: Int64 = 50 * 1024 * 1024

    /// Adds the comments of an FDF or XFDF file the person picks.
    public func importComments() async {
        guard let tab, let host, canChange else { return }
        guard let file = await host.filePicker.pickFiles([.any], multiple: false).first else { return }
        defer { file.access?.stop() }
        let name = file.url.lastPathComponent
        let xfdf = CommentExchange.isXfdf(name)
        do {
            let data = [UInt8](try Data(contentsOf: file.url))
            let fonts = fonts
            guard self.tab === tab, let result = try await MarkWork.shared.change(
                tab, host, L10n.t("Importing comments"), isCurrent: { self.tab === tab },
                { document, _ in try CommentExchange.import(document, data, xfdf: xfdf, fonts) }) else { return }
            if result.imported == 0 {
                try? tab.session.discard()
                host.showNotice(L10n.t("Nothing imported"), result.skipped > 0
                    ? L10n.t("The comments in {0} are already in this file or belong to other pages.", name)
                    : L10n.t("{0} has no comments for the pages of this file.", name), nil)
                return
            }
            if !(try MarkWork.commit(tab, host, L10n.t("Import comments"))) { return }
            host.setStatus(L10n.plural(result.imported, one: "Imported {0} comment.", other: "Imported {0} comments."))
            if result.skipped > 0 || result.withoutAppearance > 0 {
                host.showNotice(L10n.t("Some comments left out"),
                                L10n.t("{0} skipped as copies or for other pages. {1} without a drawing.", result.skipped, result.withoutAppearance), nil)
            }
        } catch is PdfReadException {
            host.showProblem(Problem(L10n.t("Not a comment file"), L10n.t("{0} could not be read. Pick an FDF or XFDF file.", name)))
        } catch {
            host.showProblem(Problems.open(error, name))
        }
    }

    /// Saves the comments as an FDF or XFDF file the person names.
    public func exportComments(xfdf: Bool) async {
        guard let tab, let host, canExport else { return }
        // The export reads a copy of the file, so the open document is not touched while it runs.
        let bytes = tab.session.current
        let password = tab.password
        let certificate = tab.certificate.flatMap { host.verifyCertificate($0) }
        let title = tab.title
        var exported: Exported?
        let name = (title as NSString).deletingPathExtension + (xfdf ? ".xfdf" : ".fdf")
        do {
            try await host.runBusy(L10n.t("Exporting comments")) { token in
                exported = try await ToolDocuments.run(token) {
                    try CommentExchange.export(ToolDocuments.open(bytes, password: password, certificate: certificate), title, xfdf: xfdf)
                }
            }
            guard let exported else { return }
            if exported.count == 0 {
                host.setStatus(L10n.t("No comments to export."))
                return
            }
            let folder = Exporter.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let written = folder.appendingPathComponent(name)
            try Data(exported.data).write(to: written)
            if await host.fileExporter.export([written]).saved.isEmpty { return }
            host.setStatus(L10n.t("Comments exported."))
            if exported.left > 0 {
                host.showNotice(L10n.t("Some content left out"), L10n.plural(
                    exported.left, one: "{0} attachment or picture stamp is not in an XFDF file. Export as FDF to keep it.",
                    other: "{0} attachments or picture stamps are not in an XFDF file. Export as FDF to keep them."), nil)
            }
        } catch is PdfReadException {
            host.showProblem(Problem(L10n.t("Comments not exported"), L10n.t("The file could not be read for export. Save a copy and try again.")))
        } catch {
            host.showProblem(Problem(L10n.t("Not saved"), L10n.t("{0} could not be written. Check that the disk has room and try again.", name)))
        }
    }

    func flatten() async {
        guard let tab, let host else { return }
        if !tab.document.isSigned {
            await flattenNow(tab, host)
            return
        }
        host.showNotice(L10n.t("Check before going on"), L10n.t("This file is signed, so changing it breaks the signatures."),
                        NoticeAction(L10n.t("Go on anyway"), { [weak self] in
                            guard let self, self.tab === tab else { return }
                            Task { await self.flattenNow(tab, host) }
                        }))
    }

    private func flattenNow(_ tab: DocumentTab, _ host: ToolHost) async {
        let burned: Int?
        do {
            burned = try await MarkWork.shared.change(tab, host, L10n.t("Flattening comments"), isCurrent: { self.tab === tab },
                                                      { document, token in try CommentExchange.flatten(document, token) })
        } catch where error is PdfReadException || error is InvalidOperationException {
            host.showProblem(Problem(L10n.t("Comments not flattened"), L10n.t("The pages could not be changed. Save a copy of the file and try again.")))
            return
        } catch {
            ChangeGate.guarded(host, L10n.t("Flatten comments")) { throw error }
            return
        }
        guard let burned else { return }
        if burned == 0 {
            try? tab.session.discard()
            host.setStatus(L10n.t("Nothing to flatten."))
            return
        }
        if (try? MarkWork.commit(tab, host, L10n.t("Flatten comments"))) == true {
            host.setStatus(L10n.plural(burned, one: "Flattened {0} mark.", other: "Flattened {0} marks."))
        }
    }

    func attachFile(_ page: Int, _ at: ViewPoint) async {
        guard let tab, let host else { return }
        guard let file = await host.filePicker.pickFiles([.any], multiple: false).first else { return }
        defer { file.access?.stop() }
        let name = file.url.lastPathComponent
        let tooBig = Problem(L10n.t("File too large"), L10n.t("{0} is over 50 MB. Attach a smaller file.", name))
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size > Self.maxAttachment {
                host.showProblem(tooBig)
                return
            }
            let data = [UInt8](try Data(contentsOf: file.url))
            let marker = makeMarker(tab)
            let made = try await MarkWork.shared.change(tab, host, L10n.t("Attaching file"), isCurrent: { self.tab === tab },
                                                        { _, _ in try marker.addAttachment(page, at, name, data) })
            if made != nil { _ = try MarkWork.commit(tab, host, L10n.t("Attach file")) }
        } catch {
            host.showProblem(Problems.open(error, name))
        }
    }
}
