#if canImport(CoreText)
import CoreText
import Foundation

// The families the text of the page can be set in, as windows/LazyPDF.App/Tools/EditContent/EditContentPanel.xaml.cs lists
// Fonts.SystemFontFamilies.

enum InstalledFonts {
    static let families: [String] = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []).sorted()
}
#else
enum InstalledFonts {
    static let families: [String] = []
}
#endif
