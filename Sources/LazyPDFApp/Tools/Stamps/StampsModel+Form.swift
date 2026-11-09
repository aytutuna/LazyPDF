import Foundation
import LazyPDFKit

// Follows windows/LazyPDF.App/Tools/Stamps/StampsPanel.Form.cs: the form's fields as one draft. A field that cannot be read gives
// no draft and a sentence for the person.

extension StampsModel {
    static var currentCulture: CultureInfo {
        let name = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? ""
        return CultureInfo(name.replacingOccurrences(of: "_", with: "-"))
    }

    func readDraft() -> (draft: StampDraft?, problem: String?) {
        guard let tab else { return (nil, nil) }
        let count = tab.pageCount
        let (pages, error) = PageChoice.resolve(form.pages, form.pagesText, count)
        if let error { return (nil, error) }
        if PageChoice.targets(pages, count).isEmpty { return (nil, L10n.t("No page in this file matches.")) }

        var style: FontStyles = []
        if form.bold { style.insert(.bold) }
        if form.italic { style.insert(.italic) }
        let family = families[min(max(form.family, 0), families.count - 1)]
        let color = colors[min(max(form.color, 0), colors.count - 1)].color
        let opacity = form.opacity / 100
        var layer: String?
        if form.layer { layer = form.mode == .watermark ? L10n.t("Watermark") : L10n.t("Background") }
        let draft: StampDraft
        switch form.mode {
        case .watermark:
            let mark = WatermarkSpec(text: form.watermarkText, fontFamily: family, fontStyle: style, color: color, opacity: opacity,
                                     rotation: form.turn, scale: form.scale / 100,
                                     anchor: StampAnchor(rawValue: form.place) ?? .center, behind: form.behind, layerName: layer, pages: pages)
            draft = StampDraft(watermark: mark, picture: picture)
        case .background:
            let fits: [BackgroundFit] = [.cover, .contain, .stretch]
            let back = BackgroundSpec(color: backColors[min(max(form.backColor, 0), backColors.count - 1)].color,
                                      fit: fits[min(max(form.fit, 0), fits.count - 1)], opacity: opacity, layerName: layer, pages: pages)
            draft = StampDraft(background: back, picture: picture)
        case .headerFooter, .bates:
            let made = form.mode == .headerFooter ? bandsSpec() : batesSpec()
            guard var spec = made.spec else { return (nil, made.problem) }
            spec.fontFamily = family
            spec.fontStyle = style
            spec.color = color
            spec.fontSize = form.textSize
            spec.marginX = form.margin
            spec.marginTop = form.margin
            spec.marginBottom = form.margin
            spec.fileName = tab.title
            spec.date = PanelDates.now()
            spec.culture = Self.currentCulture
            spec.pages = pages
            draft = StampDraft(headerFooter: spec)
        }
        let problem = draft.problem
        return (problem == nil ? draft : nil, problem)
    }

    private func bandsSpec() -> (spec: HeaderFooterSpec?, problem: String?) {
        guard let first = Int(form.firstNumber.trimmingCharacters(in: .whitespaces)) else {
            return (nil, L10n.t("The first page number must be a whole number."))
        }
        var spec = HeaderFooterSpec()
        spec.header = HeaderFooterBand(form.headerLeft, form.headerCentre, form.headerRight)
        spec.footer = HeaderFooterBand(form.footerLeft, form.footerCentre, form.footerRight)
        spec.startNumber = first
        spec.dateFormat = form.dateFormat.isEmpty ? "yyyy-MM-dd" : form.dateFormat
        return (spec, nil)
    }

    private func batesSpec() -> (spec: HeaderFooterSpec?, problem: String?) {
        guard let digits = Int(form.digits.trimmingCharacters(in: .whitespaces)), (1...18).contains(digits) else {
            return (nil, L10n.t("Digits must be a number from 1 to 18."))
        }
        if form.start.isEmpty { return (nil, L10n.t("Type the first number of the run.")) }
        guard let start = Int(form.start.trimmingCharacters(in: .whitespaces)), start >= 0 else {
            return (nil, L10n.t("The first number must be 0 or more."))
        }
        let slot = "{bates}"
        let place = form.batesPlace
        let band = HeaderFooterBand(place % 3 == 0 ? slot : "", place % 3 == 1 ? slot : "", place % 3 == 2 ? slot : "")
        var spec = HeaderFooterSpec()
        spec.header = place < 3 ? band : HeaderFooterBand()
        spec.footer = place < 3 ? HeaderFooterBand() : band
        spec.bates = BatesSpec(prefix: form.prefix, suffix: form.suffix, digits: digits, start: start)
        return (spec, nil)
    }
}
