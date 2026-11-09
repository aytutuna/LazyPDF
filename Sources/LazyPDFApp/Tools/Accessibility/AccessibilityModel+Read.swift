import Foundation
import LazyPDFKit

// Follows AccessibilityPanel.Read.cs: the reading order as a list, and reading it out with the voice the system has.

extension AccessibilityModel {
    func buildRead() {
        guard let tab, let host else { return }
        readStale = false
        readTicket += 1
        let ticket = readTicket
        readNote = L10n.t("Reading the tags")
        canRead = false
        let open = OpenCopy.of(tab, host)
        Task { [self] in
            let order = (try? await Task.detached { () throws -> String in ReadingOrder.export(try open()) }.value) ?? ""
            if ticket != readTicket { return }
            lines = ReadingLines.of(order)
            canRead = !lines.isEmpty
            readNote = lines.isEmpty
                ? L10n.t("The file has no tags, so it has no reading order. Add tags first.")
                : L10n.t("{0} lines, in the order a screen reader reads them.", lines.count)
        }
    }

    func stopReading() {
        reading?.cancel()
        speaker?.stop()
    }

    /// Where reading starts: the line picked in the list.
    public func selectLine(_ index: Int) {
        if !isReading && lines.indices.contains(index) { readIndex = index }
    }

    /// The Read aloud button: starts at the picked line, or stops when it is reading.
    public func toggleReading() {
        if reading != nil {
            stopReading()
            return
        }
        guard let host else { return }
        let voice = makeSpeaker()
        speaker = voice
        let lines = lines
        let start = max(readIndex ?? 0, 0)
        isReading = true
        reading = Task { [self] in
            do {
                for index in start..<max(lines.count, start) {
                    try Task.checkCancellation()
                    readIndex = index
                    let text = ReadingLines.spoken(lines[index])
                    if !text.isEmpty { try await voice.say(text) }
                }
                readIndex = nil
            } catch is CancellationError {
            } catch {
                // Speech can fail in many ways (no voice, a device that went away).
                host.showProblem(Problem(L10n.t("Cannot read aloud"), L10n.t("This device has no voice ready. Add one in Settings, under Spoken Content.")))
            }
            reading = nil
            speaker = nil
            isReading = false
        }
    }
}
