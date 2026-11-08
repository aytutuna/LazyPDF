import Foundation
import LazyPDFKit
#if canImport(Vision)
import Vision
#endif

// Follows windows/LazyPDF.App/Tools/Ocr/OcrLanguages.cs. Ocr and Batch share it. The languages are the ones the system's
// recognizer reads, which come with the system, so what Windows tells the person to install is only reported here.

/// `tag` is a BCP 47 tag, as the recognizer takes it.
public struct OcrLanguage: Equatable, Sendable {
    public let tag: String
    public let name: String

    public init(tag: String, name: String) {
        self.tag = tag
        self.name = name
    }
}

/// The OCR languages the system has, and the ones its person asked for that it lacks.
public struct OcrLanguageState: Equatable, Sendable {
    public let installed: [OcrLanguage]
    public let missing: [String]

    public init(installed: [OcrLanguage], missing: [String]) {
        self.installed = installed
        self.missing = missing
    }

    /// `supported` are the recognizer's tags and `wanted` the tags the person's language settings list.
    public static func make(supported: [String], wanted: [String]) -> OcrLanguageState {
        let installed = supported
            .map { OcrLanguage(tag: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let have = Set(supported.map(primary))
        var missing: [String] = []
        for tag in wanted where !have.contains(primary(tag)) {
            let name = Locale.current.localizedString(forIdentifier: tag) ?? tag
            if !missing.contains(name) { missing.append(name) }
        }
        return OcrLanguageState(installed: installed, missing: missing)
    }

    public static func read() -> OcrLanguageState {
        #if canImport(Vision)
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        #else
        let supported: [String] = []
        #endif
        return make(supported: supported, wanted: Locale.preferredLanguages)
    }

    /// The one the list starts on: the language of the app, else English, else the first.
    public func preferred(own: String? = nil) -> OcrLanguage? {
        let own = own ?? Locale.preferredLanguages.first.map(Self.primary) ?? "en"
        return installed.first { Self.primary($0.tag) == own } ?? installed.first { Self.primary($0.tag) == "en" } ?? installed.first
    }

    /// What is missing, when something is.
    public var advice: String {
        let names = missing.joined(separator: ", ")
        if installed.isEmpty { return L10n.t("This device has no text recognition language.") }
        return missing.isEmpty ? "" : L10n.t("No text recognition for {0}.", names)
    }

    private static func primary(_ tag: String) -> String {
        tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? tag.lowercased()
    }
}
