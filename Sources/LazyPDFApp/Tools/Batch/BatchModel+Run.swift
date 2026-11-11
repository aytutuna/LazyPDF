import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Batch/BatchPanel.Run.cs: running the steps and the watched folder.

extension BatchModel {
    private var currentRunner: BatchRunner {
        if let runner { return runner }
        let made = makeRunner()
        runner = made
        return made
    }

    public func run() async {
        guard let host, let output = outputFolder else { return }
        let ran = plan
        let queue = files
        var failed = 0
        var cancelled = false
        isRunning = true
        defer { isRunning = false }
        do {
            try await host.runBusy(L10n.t("Running the steps")) { token in
                for (i, file) in queue.enumerated() {
                    host.setStatus(L10n.t("File {0} of {1}", i + 1, queue.count))
                    let result: BatchResult
                    do {
                        result = try await runOne(file.url, ran, into: output.url, number: i + 1, token)
                    } catch is CancellationError {
                        cancelled = true
                        return
                    }
                    addLog(result)
                    if result.ok { removeFile(file.id) } else { failed += 1 }
                }
            }
        } catch {
            host.showProblem(Problem(L10n.t("Something went wrong"), L10n.t("{0} could not be finished. If part of it was done, Undo takes it back.", L10n.t("Run on every file"))))
        }
        host.setStatus(cancelled ? L10n.t("Cancelled.") : failed == 0 ? L10n.t("All files done")
                       : L10n.plural(failed, one: "{0} file failed", other: "{0} files failed"))
    }

    // `ran` is the copy of the steps on screen that the run was started with; a step is found again by its identity, since the
    // steps on screen may have been moved, removed or replaced by another set since.
    func runOne(_ file: URL, _ ran: BatchSet, into folder: URL, number: Int, _ token: CancelToken) async throws -> BatchResult {
        try await gate.acquire(token)
        defer { gate.release() }
        var start = ran
        for i in start.steps.indices where start.steps[i].kind == .bates {
            if let live = plan.steps.first(where: { $0.id.value == start.steps[i].id.value }) { start.steps[i].start = live.start }
        }
        let runner = currentRunner
        let now = PanelDates.now()
        let work = start
        let (done, result) = try await ToolDocuments.runAsync(token) { () async throws -> (BatchSet, BatchResult) in
            var set = work
            let result = try await runner.run(file, &set, into: folder, number: number, now: now, token: token)
            return (set, result)
        }
        if result.ok { continueNumbers(done) }
        return result
    }

    // A Bates step of the set that ran holds the next number; the step on screen takes it on, and so does the saved set of the same name.
    func continueNumbers(_ ran: BatchSet) {
        var moved = false
        for step in ran.steps where step.kind == .bates {
            guard let i = plan.steps.firstIndex(where: { $0.id.value == step.id.value }), plan.steps[i].start != step.start else { continue }
            plan.steps[i].start = step.start
            moved = true
        }
        guard moved, var saved = store.load().first(where: { $0.name.caseInsensitiveCompare(plan.name) == .orderedSame }),
              saved.steps.count == plan.steps.count else { return }
        for i in saved.steps.indices where saved.steps[i].kind == .bates && plan.steps[i].kind == .bates {
            saved.steps[i].start = plan.steps[i].start
        }
        store.save(saved)
    }

    // MARK: The watched folder

    public func setWatching(_ on: Bool) {
        if !on {
            stopWatching()
            return
        }
        if let problem = watchProblem() {
            isWatching = false
            host?.showProblem(problem)
            return
        }
        if !startWatching() { isWatching = false }
    }

    // The steps or folders changed while watching: stop if watching no longer makes sense, follow the folder if it moved.
    func recheckWatch() {
        guard isWatching else { return }
        if let problem = watchProblem() {
            stopWatching()
            host?.showProblem(problem)
        } else if let url = watchFolder?.url, !Self.sameFolder(url, watchedFolder) {
            stopWatching()
            startWatching()
        }
    }

    private func watchProblem() -> Problem? {
        if plan.steps.isEmpty { return Problem(L10n.t("No steps"), L10n.t("Add at least one step, then watch the folder.")) }
        var isFolder: ObjCBool = false
        guard let watch = watchFolder?.url, FileManager.default.fileExists(atPath: watch.path, isDirectory: &isFolder), isFolder.boolValue else {
            return Problem(L10n.t("No folder to watch"), L10n.t("Choose an existing folder to watch."))
        }
        guard let output = outputFolder?.url else {
            return Problem(L10n.t("No results folder"), L10n.t("Choose where the results go, then watch the folder."))
        }
        if Self.sameFolder(output, watch) {
            return Problem(L10n.t("Same folder"), L10n.t("Choose a results folder other than the watched one, or the results would run again."))
        }
        return nil
    }

    static func sameFolder(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        func trimmed(_ url: URL) -> String {
            var path = url.standardizedFileURL.path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return trimmed(a).caseInsensitiveCompare(trimmed(b)) == .orderedSame
    }

    @discardableResult
    private func startWatching() -> Bool {
        guard let factory = watcherFactory, let folder = watchFolder?.url else { return false }
        watchGeneration += 1
        let generation = watchGeneration
        do {
            watcher = try factory(folder, { [weak self] url in
                Task { @MainActor in self?.arrive(url, generation) }
            }, { [weak self] in
                Task { @MainActor in self?.watchFailed(generation) }
            })
        } catch {
            host?.showProblem(Problem(L10n.t("Folder cannot be watched"), L10n.t("The system does not let Lazy PDF watch this folder. Choose another.")))
            return false
        }
        watchCancel = CancelToken()
        watchedFolder = folder
        isWatching = true
        return true
    }

    public func stopWatching() {
        watchCancel?.cancel()
        watchCancel = nil
        watcher?.stop()
        watcher = nil
        arrived = []
        isWatching = false
    }

    private func arrive(_ url: URL, _ generation: Int) {
        guard generation == watchGeneration, isWatching else { return }
        arrived.append(url)
        Task { await drain() }
    }

    private func watchFailed(_ generation: Int) {
        guard generation == watchGeneration, isWatching else { return }
        let folder = watchedFolder
        stopWatching()
        addLog(BatchResult(input: folder ?? URL(fileURLWithPath: "/"), output: nil, ok: false, title: L10n.t("Watching stopped"),
                           detail: L10n.t("The folder cannot be watched any more. Check that it is there, then switch watching on again.")))
    }

    private func drain() async {
        if draining { return }
        draining = true
        defer { draining = false }
        while !arrived.isEmpty, let cancel = watchCancel, let output = outputFolder {
            let path = arrived.removeFirst()
            watched += 1
            do {
                let result = try await runOne(path, plan, into: output.url, number: watched, cancel)
                addLog(result)
                host?.setStatus(result.ok ? L10n.t("Ran {0}", path.lastPathComponent) : L10n.t("{0} failed", path.lastPathComponent))
            } catch {
                return
            }
        }
    }
}
