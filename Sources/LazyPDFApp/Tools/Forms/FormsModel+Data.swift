import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Forms/FormsPanel.Data.cs: form data in and out, as FDF, XFDF, CSV and JSON files. The files
// are chosen and saved through the host, which asks the system, since the app may read only what the person picked.

extension FormsModel {
    /// Writes the values in `dataFormat` and hands the file to the exporter, which asks where it goes.
    public func exportData() async {
        guard handIn(), let tab, let host else { return }
        let name = ((tab.title as NSString).deletingPathExtension) + "." + dataFormat.fileExtension
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Lazy PDF", isDirectory: true)
            .appendingPathComponent("Form data " + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved: [URL]
        do {
            let bytes = try FormData.export(form, dataFormat, fileName: tab.title)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            try Data(bytes).write(to: file)
            saved = await host.fileExporter.export([file])
        } catch {
            host.showProblem(Problem(L10n.t("Not exported"), L10n.t("{0} could not be written. Check the folder and try again.", name)))
            return
        }
        if !saved.isEmpty { host.setStatus(L10n.t("Form data exported.")) }
    }

    /// Fills the form from a file the person picks.
    public func importData() async {
        guard handIn() else { return }
        if signed({ [weak self] in Task { await self?.importData() } }) { return }
        guard let tab, let host else { return }
        guard let file = await host.filePicker.pickFiles([.any], multiple: false).first else { return }
        defer { file.access?.stop() }
        let name = file.url.lastPathComponent
        guard let format = FormData.format(of: name) else {
            host.showProblem(Problem(L10n.t("Unknown data file"), L10n.t("{0} is not an FDF, XFDF, CSV or JSON file. Pick another file.", name)))
            return
        }
        let data: [UInt8]
        do {
            data = [UInt8](try Data(contentsOf: file.url))
        } catch {
            host.showProblem(Problem(L10n.t("Data not read"), L10n.t("{0} could not be read. Close any program that has it open and try again.", name)))
            return
        }
        var outcome: (result: FormFillResult, rows: Int)?
        isWorking = true
        defer { endWork() }
        do {
            try await host.runBusy(L10n.t("Filling in the form")) { token in
                outcome = try await FormEdits.applyAsync(tab, fonts, L10n.t("Import form data"), token: token) { form in
                    try FormData.import(form, format, data)
                }
            }
        } catch {
            if error is PdfReadException || error is FormDataException {
                host.showProblem(Problem(L10n.t("Data not read"), L10n.t("{0} could not be read as form data. Pick a file that a form export wrote.", name)))
            } else {
                host.showProblem(problem(error))
            }
            afterEdit()
            return
        }
        afterEdit()
        if let outcome { report(outcome.result, outcome.rows) }
    }

    private func problem(_ error: Error) -> Problem {
        error is PdfPermissionException ? Problems.restricted() : FormEdits.problem(of: error)
    }

    private func report(_ result: FormFillResult, _ rows: Int) {
        guard let host else { return }
        var notes: [String] = []
        if !result.unknownFields.isEmpty {
            notes.append(L10n.plural(result.unknownFields.count, one: "{0} name matches no field: {1}.", other: "{0} names match no field: {1}.",
                                     result.unknownFields.prefix(5).joined(separator: ", ")))
        }
        if !result.rejected.isEmpty {
            notes.append(L10n.plural(result.rejected.count, one: "{0} field did not take its value: {1}.",
                                     other: "{0} fields did not take their values: {1}.", result.rejected.prefix(5).joined(separator: ", ")))
        }
        if !result.notRun.isEmpty { notes.append(FormText.scriptNotRun) }
        if rows > 1 { notes.append(L10n.t("The file has {0} rows. Only the first was used.", rows)) }
        host.setStatus(L10n.plural(result.filled, one: "{0} field filled.", other: "{0} fields filled."))
        if !notes.isEmpty { host.showNotice(L10n.t("Some data was not used"), notes.joined(separator: " "), nil) }
    }
}
