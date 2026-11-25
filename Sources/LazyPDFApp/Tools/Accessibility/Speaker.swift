import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

// Follows windows/LazyPDF.App/Tools/Accessibility/Speaker.cs: says text with the voice the system has chosen, one piece at a
// time.

/// Says text aloud.
@MainActor
public protocol Speaker: AnyObject {
    /// Returns when the text has been said, or throws `CancellationError` when `stop` or the task's cancellation ends it.
    func say(_ text: String) async throws

    func stop()
}

public struct SpeechUnavailable: Error {
    public init() {}
}

/// Stands in where the system has no speech.
@MainActor
public final class NoSpeaker: Speaker {
    public init() {}

    public func say(_ text: String) async throws {
        throw SpeechUnavailable()
    }

    public func stop() {}
}

#if canImport(AVFoundation)
// Not isolated as a whole: NSObject's own initializer is not. Everything but the delegate calls runs on the main actor.
public final class SystemSpeaker: NSObject, Speaker, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Error>?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    @MainActor
    public func say(_ text: String) async throws {
        if AVSpeechSynthesisVoice.speechVoices().isEmpty { throw SpeechUnavailable() }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finished = continuation
                synthesizer.speak(AVSpeechUtterance(string: text))
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }

    @MainActor
    public func stop() {
        if !synthesizer.stopSpeaking(at: .immediate) { end(CancellationError()) }
    }

    @MainActor
    private func end(_ error: Error?) {
        guard let waiting = finished else { return }
        finished = nil
        if let error { waiting.resume(throwing: error) } else { waiting.resume() }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.end(nil) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.end(CancellationError()) }
    }
}
#endif
