import Foundation

// Twin of windows/LazyPDF.Core/Standards/PdfAChecker.Content.cs: pages as drawn: content stream operators, colour,
// transparency, images, forms and fonts in use. The interpreter walks each page and enters forms and patterns; resource
// dictionaries are scanned as well, so a graphics state or image that is defined but not yet painted is held to the same
// rules, though only what is painted counts as a use of a device colour space.
//
// The C# visitor throws PdfReadException out of the interpreter when a form is past the budget. The Swift interpreter's
// callbacks do not throw, so the visitor keeps the first failure, does nothing after it, and the page's walk throws it
// when the run is over.

extension PdfAChecker {
    static let operators: Set<String> = [
        "b", "B", "b*", "B*", "BDC", "BI", "BMC", "BT", "BX", "c", "cm", "CS", "cs", "d", "d0", "d1", "Do", "DP", "EI", "EMC", "ET", "EX",
        "f", "F", "f*", "G", "g", "gs", "h", "i", "ID", "j", "J", "K", "k", "l", "m", "M", "MP", "n", "q", "Q", "re", "RG", "rg", "ri",
        "s", "S", "SC", "sc", "SCN", "scn", "sh", "T*", "Tc", "Td", "TD", "Tf", "Tj", "TJ", "TL", "Tm", "Tr", "Ts", "Tw", "Tz", "v", "w",
        "W", "W*", "y", "'", "\"",
    ]

    static let blendModes: Set<String> = [
        "Normal", "Compatible", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "ColorDodge", "ColorBurn", "HardLight", "SoftLight",
        "Difference", "Exclusion", "Hue", "Saturation", "Color", "Luminosity",
    ]

    static let maxScanDepth = 32
    static let maxFontCodes = 70_000
    static let maxOperations = 10_000_000

    static let renderingIntents = ["AbsoluteColorimetric", "RelativeColorimetric", "Saturation", "Perceptual"]

    struct DeviceUse: Hashable {
        let family: String
        let place: String
        let scope: ObjectIdentifier?
    }

    var clauseImages: String { c("6.2.4", "6.2.8") }
    var clauseForms: String { c("6.2.5", "6.2.9") }
    var clauseReference: String { c("6.2.6", "6.2.9") }
    var clausePostScript: String { c("6.2.7", "6.2.9") }
    var clauseTransparency: String { c("6.4", "6.2.10") }
    var clauseState: String { c("6.2.8", "6.2.5") }
    var clauseIntent: String { c("6.2.9", "6.2.6") }

    func checkPages() {
        let interpreter = ContentInterpreter(document)
        let pages = document.pages
        var i = 0
        while i < pages.count && !overBudget {
            let page = pages[i]
            let place = PdfAText.pageName(i + 1)
            checkGroup(page.dictionary, place, page.resources, true)
            checkTriggers(page.dictionary, place, false)
            if (part == 2 || part == 3) && page.dictionary.containsKey("AA") { add("6.5.2", place, PdfAText.pageTriggers) }
            scanResources(page.resources, place)
            do {
                try checkContent(page.contents(), place)
                let visitor = Visitor(self, place, page.resources)
                interpreter.run(page, visitor)
                if let failure = visitor.failure { throw failure }
                if interpreter.isTruncated { add("6.1.7", place, PdfAText.tooMuchContent) }
            } catch {
                unreadable(place)
            }
            checkAnnotations(page, i + 1, interpreter)
            i += 1
        }
        if overBudget { unreadable(PdfAText.pageName(Swift.max(1, i))) }
    }

    func useDevice(_ family: String, _ place: String, _ scope: PdfDictionary?) {
        if !deviceUses.insert(DeviceUse(family: family, place: place, scope: scope.map { ObjectIdentifier($0) })).inserted { return }
        let allowed: Bool
        switch family {
        case "DeviceGray": allowed = intentComponents != 0 || hasDefault(scope, "DefaultGray")
        case "DeviceRGB": allowed = intentComponents == 3 || hasDefault(scope, "DefaultRGB")
        default: allowed = intentComponents == 4 || hasDefault(scope, "DefaultCMYK")
        }
        if !allowed { add(c("6.2.3.3", "6.2.4.3"), place, PdfAText.deviceColor(family)) }
    }

    // A default space counts in the resource dictionary of the content that uses the device space (ISO 32000-1 8.6.5.6).
    private func hasDefault(_ scope: PdfDictionary?, _ name: String) -> Bool {
        document.dict(scope, "ColorSpace")?.containsKey(name) == true
    }

    @discardableResult
    func checkContent(_ data: [UInt8], _ place: String) throws -> [ContentOperation] {
        var depth = 0, deepest = 0
        work += data.count
        let operations = try ContentParser.parse(data, Self.maxOperations)
        if Self.hasBadHexString(data, operations) { add("6.1.6", place, PdfAText.hexString) }
        for op in operations {
            for operand in op.operands { checkOperand(operand, place) }
            if let image = op.image { checkOperand(image.dictionary, place) }
            switch op.operator {
            case "q":
                depth += 1
                deepest = Swift.max(deepest, depth)
            case "Q":
                depth = Swift.max(0, depth - 1)
            case "ri":
                if let intent = op.operands.first as? PdfName { checkIntent(intent.value, place) }
            default:
                break
            }
            if !Self.operators.contains(op.operator) { add(c("6.2.10", "6.2.2"), place, PdfAText.unknownOperator(op.operator)) }
        }
        if deepest > 28 { add(c("6.1.12", "6.1.13"), place, PdfAText.graphicsNesting) }
        return operations
    }

    private func checkOperand(_ operand: PdfObject, _ place: String) {
        checkLimits(operand, place)
        switch operand {
        case let array as PdfArray: for child in array.items { checkOperand(child, place) }
        case let dictionary as PdfDictionary: for entry in dictionary.entries { checkOperand(entry.value, place) }
        default: break
        }
    }

    func checkIntent(_ intent: String?, _ place: String) {
        if let intent, !Self.renderingIntents.contains(intent) { add(clauseIntent, place, PdfAText.renderingIntent(intent)) }
    }

    func checkGroup(_ owner: PdfDictionary, _ place: String, _ scope: PdfDictionary?, _ countDevice: Bool) {
        guard let group = document.dict(owner, "Group") else { return }
        if isPart1 && document.name(group, "S") == "Transparency" { add(clauseTransparency, place, PdfAText.transparencyGroup) }
        if group.containsKey("CS") { checkColorSpace(group["CS"], place, scope, countDevice) }
    }

    func scanResources(_ resources: PdfDictionary?, _ place: String) {
        guard let resources, scanDepth < Self.maxScanDepth, resourcesSeen.insert(ObjectIdentifier(resources)).inserted else { return }
        scanDepth += 1
        defer { scanDepth -= 1 }
        scanCategories(resources, place)
    }

    private func scanCategories(_ resources: PdfDictionary, _ place: String) {
        for case let state as PdfDictionary in entries(resources, "ExtGState") { checkExtGState(state, place) }
        for space in entries(resources, "ColorSpace") { checkColorSpace(space, place, resources, false) }
        for shading in entries(resources, "Shading") { checkShading(shading, place, resources, false) }
        for pattern in entries(resources, "Pattern") {
            if let tiling = pattern as? PdfStream {
                checkFormStream(tiling, place)
            } else if let dictionary = pattern as? PdfDictionary {
                if let state = document.dict(dictionary, "ExtGState") { checkExtGState(state, place) }
                checkShading(dictionary["Shading"], place, resources, false)
            }
        }
        for case let xobject as PdfStream in entries(resources, "XObject") {
            switch document.name(xobject.dictionary, "Subtype") {
            case "Image": checkImage(xobject, place)
            case "Form": checkFormStream(xobject, place)
            case "PS": add(clausePostScript, place, PdfAText.postScriptObject)
            default: break
            }
        }
        for case let font as PdfDictionary in entries(resources, "Font") {
            scanResources(document.dict(font, "Resources"), place)
            for case let glyphProcedure as PdfStream in entries(font, "CharProcs") { checkFormStream(glyphProcedure, place) }
        }
    }

    func entries(_ owner: PdfDictionary, _ key: String) -> [PdfObject] {
        guard let category = document.dict(owner, key) else { return [] }
        return category.entries.prefix(100_000).compactMap { document.resolve($0.value) }
    }

    private func checkExtGState(_ state: PdfDictionary, _ place: String) {
        if let mask = document.dict(state, "SMask"), let group = document.stream(mask, "G") {
            checkFormStream(group, place)
            scanText(group, document.dict(group.dictionary, "Resources"), place, false)
        }
        if state.containsKey("TR") { add(clauseState, place, PdfAText.transferFunction) }
        if state.containsKey("TR2") && document.name(state, "TR2") != "Default" { add(clauseState, place, PdfAText.transferFunction) }
        if state.containsKey("HTP") { add(clauseState, place, PdfAText.halftone) }
        checkIntent(document.name(state, "RI"), place)
        let blend = document.resolve(state["BM"])
        if !isPart1 {
            let modes: [String?]
            if let list = blend as? PdfArray {
                modes = list.items.prefix(16).map { (document.resolve($0) as? PdfName)?.value }
            } else {
                modes = [(blend as? PdfName)?.value]
            }
            for case let name? in modes where !Self.blendModes.contains(name) { add(clauseTransparency, place, PdfAText.unknownBlendMode(name)) }
            return
        }
        let mode: String?
        if let first = (blend as? PdfArray)?.items.first {
            mode = (document.resolve(first) as? PdfName)?.value
        } else {
            mode = (blend as? PdfName)?.value
        }
        if let mode, mode != "Normal", mode != "Compatible" { add(clauseTransparency, place, PdfAText.blendMode(mode)) }
        if let strokeAlpha = document.number(state, "CA"), strokeAlpha < 1 { add(clauseTransparency, place, PdfAText.opacity) }
        if let fillAlpha = document.number(state, "ca"), fillAlpha < 1 { add(clauseTransparency, place, PdfAText.opacity) }
        if let mask = document.resolve(state["SMask"]), (mask as? PdfName)?.value != "None" { add(clauseTransparency, place, PdfAText.softMask) }
    }

    func checkFormStream(_ form: PdfStream, _ place: String) {
        if !streamsSeen.insert(ObjectIdentifier(form)).inserted { return }
        let d = form.dictionary
        if d.containsKey("Ref") { add(clauseReference, place, PdfAText.referenceXObject) }
        if document.name(d, "Subtype2") == "PS" || d.containsKey("PS") { add(clausePostScript, place, PdfAText.postScriptObject) }
        if d.containsKey("OPI") { add(clauseForms, place, PdfAText.opi) }
        let resources = document.dict(d, "Resources")
        checkGroup(d, place, resources, false)
        scanResources(resources, place)
        if overBudget { return }
        measure(form, place)
    }

    func checkImage(_ image: PdfStream, _ place: String) {
        if !streamsSeen.insert(ObjectIdentifier(image)).inserted { return }
        let d = image.dictionary
        if document.bool(d, "Interpolate") == true { add(clauseImages, place, PdfAText.interpolate) }
        if d.containsKey("OPI") { add(clauseImages, place, PdfAText.opi) }
        if d.containsKey("Alternates") { add(clauseImages, place, PdfAText.alternates) }
        checkIntent(document.name(d, "Intent"), place)
        if document.bool(d, "ImageMask") != true { checkColorSpace(d["ColorSpace"], place, nil, false) }
        if isPart1 {
            if document.resolve(d["SMask"]) != nil || (document.integer(d, "SMaskInData") ?? 0) > 0 { add(clauseTransparency, place, PdfAText.imageTransparency) }
            if filterNames(d).contains("JPXDecode") { add(clauseImages, place, PdfAText.jpx) }
        }
    }

    func checkInlineImage(_ image: PdfDictionary, _ place: String, _ scope: PdfDictionary?) {
        if document.bool(image, "Interpolate") == true { add(clauseImages, place, PdfAText.interpolate) }
        checkFilters(image, place, true)
        if document.bool(image, "ImageMask") != true, let space = image["ColorSpace"] { checkColorSpace(space, place, scope, true) }
    }

    func checkShading(_ shading: PdfObject?, _ place: String, _ scope: PdfDictionary?, _ countDevice: Bool) {
        let d: PdfDictionary?
        switch document.resolve(shading) {
        case let stream as PdfStream: d = stream.dictionary
        case let dictionary as PdfDictionary: d = dictionary
        default: d = nil
        }
        if let d { checkColorSpace(d["ColorSpace"], place, scope, countDevice) }
    }

    /// Device spaces count as used, in the resources `scope`, only where `countDevice` is set; the alternate
    /// of a Separation is not a use, and a space merely listed in a resource dictionary is not one until something paints with it.
    func checkColorSpace(_ space: PdfObject?, _ place: String, _ scope: PdfDictionary?, _ countDevice: Bool, _ depth: Int = 0) {
        guard let space = document.resolve(space), depth <= 8 else { return }
        if let name = space as? PdfName {
            guard countDevice else { return }
            switch name.value {
            case "DeviceGray", "DeviceRGB", "DeviceCMYK": useDevice(name.value, place, scope)
            case "G": useDevice("DeviceGray", place, scope)
            case "RGB": useDevice("DeviceRGB", place, scope)
            case "CMYK": useDevice("DeviceCMYK", place, scope)
            default: break
            }
            return
        }
        guard let array = space as? PdfArray, let head = array.items.first, let family = document.resolve(head) as? PdfName else { return }
        func item(_ i: Int) -> PdfObject? { i < array.items.count ? array.items[i] : nil }
        switch family.value {
        case "ICCBased":
            if let profile = document.resolve(item(1)) as? PdfStream { checkProfile(profile, place) }
        case "Indexed", "I", "Pattern":
            checkColorSpace(item(1), place, scope, countDevice, depth + 1)
        case "Separation":
            checkSeparation(array, place)
            checkColorSpace(item(2), place, scope, false, depth + 1)
        case "DeviceN":
            if let colorants = document.resolve(item(1)) as? PdfArray, colorants.items.count > (isPart1 ? 8 : 32) {
                add(c("6.1.12", "6.1.13"), place, PdfAText.tooManyColorants(isPart1 ? 8 : 32))
            }
            checkColorSpace(item(2), place, scope, false, depth + 1)
        case "DeviceGray", "DeviceRGB", "DeviceCMYK":
            checkColorSpace(head, place, scope, countDevice, depth + 1)
        default:
            break
        }
    }

    // 6.2.3.4 / 6.2.4.4: every Separation of one colorant name has the same alternate space and tint transform.
    private func checkSeparation(_ array: PdfArray, _ place: String) {
        guard array.items.count >= 4, let colorant = document.resolve(array.items[1]) as? PdfName else { return }
        let signature = "\(array.items[2])|\(array.items[3])"
        if let known = separations[colorant.value] {
            if known != signature { add(c("6.2.3.4", "6.2.4.4"), place, PdfAText.separationDiffers(colorant.value)) }
        } else {
            separations[colorant.value] = signature
        }
    }

    private func checkProfile(_ profile: PdfStream, _ place: String) {
        if !streamsSeen.insert(ObjectIdentifier(profile)).inserted || overBudget { return }
        let clause = c("6.2.3.2", "6.2.4.2")
        guard let n = document.integer(profile.dictionary, "N"), n == 1 || n == 3 || n == 4 else {
            add(clause, place, PdfAText.profileComponents)
            return
        }
        let data: [UInt8]
        do {
            data = try document.data(profile, 32 << 20)
            work += data.count
        } catch {
            add(clause, place, PdfAText.profileUnreadable)
            return
        }
        if let problem = Self.iccProblem(data, n, isPart1 ? 2 : 4) { add(clause, place, problem) }
    }

    /// What is wrong with an ICC profile for PDF/A, or nil: size, signature, class, colour space against /N, major version.
    /// An output intent profile must be of class prtr or mntr and a plain RGB, gray or CMYK one; an ICCBased space may also be scnr or spac, or Lab with /N 3.
    static func iccProblem(_ profile: [UInt8], _ components: Int, _ highestVersion: Int, _ outputIntent: Bool = false) -> String? {
        if profile.count < 128 || !profile.hasPattern(Array("acsp".utf8), at: 36) { return PdfAText.profileUnreadable }
        // Encoding.ASCII reads a byte above 127 as "?".
        func ascii(_ at: Int) -> String {
            String(String.UnicodeScalarView(profile[at..<(at + 4)].map { $0 < 128 ? Unicode.Scalar($0) : "?" }))
        }
        let kind = ascii(12)
        let space = ascii(16)
        if kind != "mntr" && kind != "prtr" && (outputIntent || (kind != "scnr" && kind != "spac")) { return PdfAText.profileClass(kind) }
        let wanted = components == 1 ? "GRAY" : components == 3 ? "RGB " : "CMYK"
        if space != wanted && !(components == 3 && !outputIntent && space == "Lab ") { return PdfAText.profileSpace }
        if Int(profile[8]) > highestVersion { return PdfAText.profileVersion(Int(profile[8])) }
        return nil
    }

    // A shading pattern is painted in the space of its shading, and an Indexed space paints through its base.
    func useColor(_ color: PdfColor, _ place: String, _ scope: PdfDictionary?) {
        if let pattern = color.pattern as? PdfDictionary { checkShading(pattern["Shading"], place, scope, true) }
        let used = color.space.family == "Pattern" ? color.space.base : color.space
        if used?.family == "Indexed" {
            checkColorSpace(used?.definition, place, scope, true)
        } else if let family = used?.family, family == "DeviceGray" || family == "DeviceRGB" || family == "DeviceCMYK" {
            useDevice(family, place, scope)
        }
    }

    func noteGlyph(_ context: ContentContext, _ glyph: GlyphInfo, _ place: String, _ scope: PdfDictionary?) {
        let mode = context.state.renderMode % 4
        if mode == 0 || mode == 2 {
            useColor(context.state.fillColor, place, scope)
            scanCell(context.state.fillColor, place, scope)
        }
        if mode == 1 || mode == 2 {
            useColor(context.state.strokeColor, place, scope)
            scanCell(context.state.strokeColor, place, scope)
        }
        let font = glyph.font
        if context.state.renderMode != 3 { renderedFonts.insert(ObjectIdentifier(font.dictionary)) }
        let key = font.isComposite ? glyph.character.cid : glyph.code
        if key < 0 || key > 0xFFFF { return }
        let used = usesOf(font.dictionary)
        if used.count >= Self.maxFontCodes || !used.insert(key) { return }
        if font.isType3 {
            scanProcedure(font, glyph.code, scope, place)
            return
        }
        let program = font.isComposite ? font.programCidWidth(key) : font.programWidth(key)
        if let own = program, abs(own - glyph.character.width) > 1 {
            add(c("6.3.6", "6.2.11.5"), PdfAText.fontName(font.baseFont), PdfAText.widthDiffers(key, glyph.character.width, own))
        }
    }

    final class Visitor: ContentVisitor {
        private let checker: PdfAChecker
        private let place: String
        // The resources whose Default spaces apply: those of the innermost form that has any, else the page's.
        private var scopes: [PdfDictionary?]
        private var patterns = Set<ObjectIdentifier>()
        private(set) var failure: Error?

        init(_ checker: PdfAChecker, _ place: String, _ resources: PdfDictionary?) {
            self.checker = checker
            self.place = place
            scopes = [resources]
            super.init()
        }

        private var scope: PdfDictionary? { scopes.last ?? nil }

        override func showGlyph(_ context: ContentContext, _ glyph: GlyphInfo) {
            if failure != nil { return }
            checker.useMask(context, place, scope)
            checker.noteGlyph(context, glyph, place, scope)
        }

        override func paintPath(_ context: ContentContext, _ path: PathInfo) {
            if failure != nil { return }
            checker.useMask(context, place, scope)
            if path.fill { checker.useColor(context.state.fillColor, place, scope) }
            if path.stroke { checker.useColor(context.state.strokeColor, place, scope) }
        }

        override func paintImage(_ context: ContentContext, _ image: ImageInfo) {
            if failure != nil { return }
            checker.useMask(context, place, scope)
            if let stream = image.stream {
                checker.checkImage(stream, place)
                if !image.isMask { checker.checkColorSpace(image.dictionary["ColorSpace"], place, scope, true) }
            } else {
                checker.checkInlineImage(image.dictionary, place, scope)
            }
            if !image.isMask { return }
            checker.useColor(context.state.fillColor, place, scope)
            checker.scanCell(context.state.fillColor, place, scope)
        }

        override func paintShading(_ context: ContentContext, _ shading: ShadingInfo) {
            if failure != nil { return }
            checker.useMask(context, place, scope)
            checker.checkShading(shading.shading, place, scope, true)
        }

        override func beginForm(_ context: ContentContext, _ form: FormInfo) {
            if failure != nil { return }
            checker.checkFormStream(form.stream, place)
            do {
                try checker.charge(form.stream, place)
            } catch {
                failure = error
                return
            }
            scopes.append(checker.document.dict(form.stream.dictionary, "Resources") ?? scope)
            if context.forms.count >= PdfAChecker.maxFormDepth && checker.skipsContent(form.stream, context, { self.find($0, $1) }, patterns) {
                checker.add("6.1.7", place, PdfAText.tooMuchContent)
            }
            if form.isPattern { patterns.insert(ObjectIdentifier(form.stream)) }
            checker.checkGroup(form.stream.dictionary, place, scope, true)
        }

        override func endForm(_ context: ContentContext, _ form: FormInfo) {
            if failure != nil { return }
            if scopes.count > 1 { scopes.removeLast() }
        }

        // The interpreter looks a name up in the innermost resources that have the category, then outwards.
        private func find(_ category: String, _ name: String) -> PdfObject? {
            for scope in scopes.reversed() {
                if let entries = checker.document.dict(scope, category), entries.containsKey(name) { return checker.document.resolve(entries[name]) }
            }
            return nil
        }
    }
}
