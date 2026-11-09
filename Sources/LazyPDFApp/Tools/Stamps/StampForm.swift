import Foundation
import LazyPDFKit

// The fields of windows/LazyPDF.App/Tools/Stamps/StampsPanel.xaml as one value, so that the model sees every change to the form in
// one place. The indices pick from the lists the model offers; the sliders are in the units their readouts show.

public enum StampMode: Int, CaseIterable {
    case watermark, background, headerFooter, bates
}

public struct StampForm: Equatable {
    public var mode = StampMode.watermark

    // Watermark
    public var watermarkText = L10n.t("Confidential")
    public var scale = 60.0
    public var turn = 45.0
    public var place = 4
    public var behind = false

    // Background
    public var backColor = 2
    public var fit = 0

    // Watermark and background
    public var opacity = 30.0
    public var layer = false

    // Header and footer
    public var headerLeft = ""
    public var headerCentre = ""
    public var headerRight = ""
    public var footerLeft = ""
    public var footerCentre = "{page}"
    public var footerRight = ""
    public var firstNumber = "1"
    public var dateFormat = "yyyy-MM-dd"

    // Bates numbers
    public var prefix = ""
    public var suffix = ""
    public var digits = "6"
    public var start = "1"
    public var batesPlace = 5

    // Text
    public var family = 0
    public var bold = true
    public var italic = false
    public var color = 0
    public var textSize = 10.0
    public var margin = 36.0

    // Pages
    public var pages = PageSet.all
    public var pagesText = ""

    public init() {}
}
