import Foundation

// Twin of windows/LazyPDF.Core/Structure/ViewerSettings.cs: the catalog entries that say how a file opens (ISO 32000-1
// 7.7.2, 12.2).
//
// The C# reads the page mode with Enum.TryParse, which also takes a number or a comma list as a name and then holds a
// value the enum does not define. Here only the names read; anything else is the default.

/// What the viewer shows beside the page when the file opens (/PageMode).
public enum PageMode: String {
    case useNone = "UseNone"
    case useOutlines = "UseOutlines"
    case useThumbs = "UseThumbs"
    case fullScreen = "FullScreen"
    case useOC = "UseOC"
    case useAttachments = "UseAttachments"
}

/// How the pages are laid out when the file opens (/PageLayout).
public enum PageLayout: String {
    case singlePage = "SinglePage"
    case oneColumn = "OneColumn"
    case twoColumnLeft = "TwoColumnLeft"
    case twoColumnRight = "TwoColumnRight"
    case twoPageLeft = "TwoPageLeft"
    case twoPageRight = "TwoPageRight"
}

/// The catalog entries that say how a file opens: language, page mode and layout, and the /ViewerPreferences. `duplex`
/// is Simplex, DuplexFlipShortEdge or DuplexFlipLongEdge; `numCopies` is 2 to 5 or nil.
public struct ViewerSettings: Equatable {
    public var language: String?
    public var displayDocTitle: Bool
    public var pageMode: PageMode
    public var pageLayout: PageLayout
    public var hideToolbar: Bool
    public var hideMenubar: Bool
    public var hideWindowUI: Bool
    public var fitWindow: Bool
    public var centerWindow: Bool
    public var rightToLeft: Bool
    public var printScalingNone: Bool
    public var duplex: String?
    public var numCopies: Int?

    public init(_ language: String?, _ displayDocTitle: Bool, _ pageMode: PageMode, _ pageLayout: PageLayout, _ hideToolbar: Bool,
                _ hideMenubar: Bool, _ hideWindowUI: Bool, _ fitWindow: Bool, _ centerWindow: Bool, _ rightToLeft: Bool,
                _ printScalingNone: Bool, _ duplex: String?, _ numCopies: Int?) {
        self.language = language
        self.displayDocTitle = displayDocTitle
        self.pageMode = pageMode
        self.pageLayout = pageLayout
        self.hideToolbar = hideToolbar
        self.hideMenubar = hideMenubar
        self.hideWindowUI = hideWindowUI
        self.fitWindow = fitWindow
        self.centerWindow = centerWindow
        self.rightToLeft = rightToLeft
        self.printScalingNone = printScalingNone
        self.duplex = duplex
        self.numCopies = numCopies
    }

    public static func read(_ document: PdfDocument) -> ViewerSettings {
        let catalog = document.catalog
        let prefs = document.dict(catalog, "ViewerPreferences")
        func flag(_ key: String) -> Bool { document.bool(prefs, key) == true }
        var copies: Int?
        if let n = document.integer(prefs, "NumCopies"), n >= 2, n <= 5 { copies = n }
        return ViewerSettings(
            PdfText.read(document, catalog, "Lang"), flag("DisplayDocTitle"),
            document.name(catalog, "PageMode").flatMap { PageMode(rawValue: $0) } ?? .useNone,
            document.name(catalog, "PageLayout").flatMap { PageLayout(rawValue: $0) } ?? .singlePage,
            flag("HideToolbar"), flag("HideMenubar"), flag("HideWindowUI"), flag("FitWindow"), flag("CenterWindow"),
            document.name(prefs, "Direction") == "R2L", document.name(prefs, "PrintScaling") == "None",
            document.name(prefs, "Duplex"), copies)
    }

    /// Stores the settings. A value that is the default is taken out rather than written, and keys of
    /// /ViewerPreferences not listed here stay.
    public func write(_ document: PdfDocument) {
        let catalog = document.catalog
        if let language, !language.isEmpty {
            catalog["Lang"] = PdfText.toObject(language)
        } else {
            catalog.remove("Lang")
        }
        Self.setName(catalog, "PageMode", pageMode == .useNone ? nil : pageMode.rawValue)
        Self.setName(catalog, "PageLayout", pageLayout == .singlePage ? nil : pageLayout.rawValue)

        let prefs = document.dict(catalog, "ViewerPreferences") ?? PdfDictionary()
        func flag(_ key: String, _ on: Bool) {
            if on {
                prefs[key] = PdfBoolean(true)
            } else {
                prefs.remove(key)
            }
        }
        flag("DisplayDocTitle", displayDocTitle)
        flag("HideToolbar", hideToolbar)
        flag("HideMenubar", hideMenubar)
        flag("HideWindowUI", hideWindowUI)
        flag("FitWindow", fitWindow)
        flag("CenterWindow", centerWindow)
        Self.setName(prefs, "Direction", rightToLeft ? "R2L" : nil)
        Self.setName(prefs, "PrintScaling", printScalingNone ? "None" : nil)
        Self.setName(prefs, "Duplex", duplex)
        if let numCopies, numCopies >= 2, numCopies <= 5 {
            prefs["NumCopies"] = PdfNumber(numCopies)
        } else {
            prefs.remove("NumCopies")
        }

        if prefs.count == 0 {
            catalog.remove("ViewerPreferences")
        } else if document.dict(catalog, "ViewerPreferences") == nil {
            catalog["ViewerPreferences"] = prefs
        }
    }

    private static func setName(_ dictionary: PdfDictionary, _ key: String, _ value: String?) {
        if let value {
            dictionary[key] = PdfName(value)
        } else {
            dictionary.remove(key)
        }
    }
}
