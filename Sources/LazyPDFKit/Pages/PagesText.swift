import Foundation

// Twin of windows/LazyPDF.Core/Pages/PagesText.cs: texts the pages tools show.

public enum PagesText {
    public static var rangeUsage: String { L10n.t("Type pages like 1-3, 5") }

    public static func pastTheEnd(_ page: Int, _ count: Int) -> String {
        L10n.plural(count, one: "Page {1} is past the end ({0} page)", other: "Page {1} is past the end ({0} pages)", page)
    }
}
